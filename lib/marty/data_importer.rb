module Marty
  class DataImporterError < StandardError
    attr_reader :lines

    def initialize(message, lines)
      super(message)
      @lines = lines
    end
  end

  class DataImporter
    MCFLY_COLUMNS = Set[
                        "id",
                        "group_id",
                        "user_id",
                        "created_dt",
                        "obsoleted_dt",
                        "o_user_id",
                       ]

    class RowProcessor
      attr_accessor :klass, :headers, :dt, :key_attrs, :hmap

      EXCEL_START_DATE = Date.parse('1/1/1900')-2

      # Given a Mcfly class, return the set of attributes (excluding id)
      # used to uniquely identify an instance.
      def self.get_keys(klass)
        raise "bad class arg #{klass}" unless
          klass.is_a?(Class) && klass < ActiveRecord::Base

        attrs = klass.const_get(:MCFLY_UNIQUENESS)

        raise "class has no :MCFLY_UNIQUENESS" unless attrs

        attrs = attrs[0..-2] + attrs.last.fetch(:scope, []) if
          attrs.last.is_a?(Hash)
        attrs -= [:obsoleted_dt]

        raise "key list for #{klass} is empty" if attrs.empty?
        attrs
      end

      def self.assoc_info(klass, a)
        assoc_class = klass.reflect_on_association(a.to_sym).klass
        keys = self.get_keys(assoc_class) rescue nil

        if keys
          raise "#{klass}-#{assoc_class} key list too long: #{keys}" unless
            keys.length == 1
          assoc_key = keys.first
        else
          assoc_key = assoc_class.attribute_names.reject{|x| x=="id"}.first
        end

        {assoc_key: assoc_key, assoc_class: assoc_class, mcfly: keys}
      end

      FLOAT_PAT = /^-?\d+(\.\d+)?$/

      PATS = {
        integer: /^-?\d+(\.0+)?$/,
        float:   FLOAT_PAT,
        decimal: FLOAT_PAT,
      }

      def convert(v, type)
        pat = PATS[type]

        raise "bad #{type} #{v.inspect}" if
          v.is_a?(String) && pat && !(v =~ pat)

        case type
        when :boolean
          case v.downcase
          when "true" then true
          when "false" then false
          else raise "unknown boolean #{v}"
          end
        when :string, :text
          v
        when :integer
          v.to_i
        when :float
          v.to_f
        when :decimal
          v.to_d
        when :date
          # Dates are kept as float in Google spreadsheets.  Need to
          # convert them to dates. FIXME: 'infinity' as a date in
          # Rails 3.2 appears to be broken. Setting a date field to
          # 'infinity' sets it to nil.
          v =~ FLOAT_PAT ? EXCEL_START_DATE + v.to_f :
            Mcfly.is_infinity(v) ? 'infinity' : v.to_date
        when :datetime
          Mcfly.is_infinity(v) ? 'infinity' : v.to_datetime
        when :numrange, :int4range, :int8range
          v.to_s
        when :float_array, :json
          JSON.parse Marty::DataExporter.decode_json(v)
        else
          raise "unknown type #{type} for #{v}"
        end
      end

      def initialize(klass, headers, dt)
        @klass     = klass
        @headers   = headers
        @dt        = dt
        @key_attrs = self.class.get_keys(klass)

        # # HACK: not sure why there's a nil at the end of headers sometimes
        # headers.pop if headers[-1].nil?

        raise "row headers have nil! #{headers.inspect}" unless headers.all?

        associations = klass.reflect_on_all_associations.map(&:name)

        cols = klass.columns.each_with_object({}) { |c, h|
          h[c.name] = c
        }

        @hmap = headers.each_with_object({}) do
          |a, h|
          # handle klass__attr type headers generated by Netzke.  Just
          # keeps klass since we should be able to find the key attr.
          a = $1 if a =~ /(.*)__/

          if associations.member?(a.to_sym)
            h[a] = self.class.assoc_info(klass, a)
            next
          end

          raise "unknown column #{a}" unless cols[a]

          # for JSON fields in Rails 3.x type is nil, so use sql_type
          type = cols[a].type || cols[a].sql_type
          type = "#{type}_array" if cols[a].array
          h[a] = type.to_sym
        end
      end

      def create_or_update(row)
        options = row.each_with_object({}) { |(a, v), h|
          # ignore Mcfly columns
          next if Marty::DataImporter::MCFLY_COLUMNS.member? a

          a = $1 if a =~ /(.*)__/

          if hmap[a].is_a? Hash
            if !v
              h["#{a}_id"] = nil
              next
            end

            if v.is_a? ActiveRecord::Base
              av = v
            else
              srch = {hmap[a][:assoc_key] => v}
              srch[:obsoleted_dt] = 'infinity' if hmap[a][:mcfly]
              av = hmap[a][:assoc_class].where(srch).first
            end

            raise "#{v.inspect} not found #{hmap[a][:assoc_class]}" unless av

            h["#{a}_id"] = av.id
          else
            raise "bad col #{a} value #{v}, row: #{row}" unless hmap[a]

            # if it's not a hash (association) then its a type symbol
            h[a] = v && convert(v, hmap[a])
          end
        }

        find_options = options.select { |k,v| key_attrs.member? k.to_sym }

        raise "invalid entry" if find_options.empty?

        find_options['obsoleted_dt'] = 'infinity'

        obj = klass.where(find_options).first || klass.new

        options.each do
          |k, v|
          # For each attr, check to see if it's begin changed before
          # setting it.  The AR obj.changed? doesn't work properly
          # with array, JSON or lazy attrs.
          obj.send("#{k}=", v) if obj.send(k) != v
        end

        # FIXME: obj.changed? doesn't work properly for timestamp
        # fields in Rails 3.2. It evaluates to true even when datetime
        # is not changed.  Caused by lack of awareness of timezones.
        tag = obj.new_record? ? :create : (obj.changed? ? :update : :same)

        raise "old created_dt >= current #{obj} #{obj.created_dt} #{dt}" if
          (tag == :update) && !Mcfly.is_infinity(dt) && (obj.created_dt > dt)

        obj.created_dt = dt unless tag == :same || Mcfly.is_infinity(dt)
        obj.save!

        [tag, obj.id]
      end
    end

    # perform cleaning and do_import and summarize its results
    def self.do_import_summary(klass,
                               data,
                               dt='infinity',
                               cleaner_function=nil,
                               validation_function=nil,
                               col_sep="\t",
                               allow_dups=false
                               )

      recs = self.do_import(klass,
                            data,
                            dt,
                            cleaner_function,
                            validation_function,
                            col_sep,
                            allow_dups,
                            )

      recs.each_with_object(Hash.new(0)) {|(op, id), h|
        h[op] += 1
      }
    end

    # Given a Mcfly klass and CSV data, import data into the database
    # and report on affected rows.  Result is an array of tuples.
    # Each tuple is associated with one data row and looks like [tag,
    # id].  Tag is one of :same, :update, :create and "id" is the id
    # of the affected row.
    def self.do_import(klass,
                       data,
                       dt='infinity',
                       cleaner_function=nil,
                       validation_function=nil,
                       col_sep="\t",
                       allow_dups=false
                       )

      parsed = data.is_a?(Array) ? data :
        CSV.new(data, headers: true, col_sep: col_sep)

      klass.transaction do
        cleaner_ids = cleaner_function ? klass.send(cleaner_function.to_sym) :
          []

        raise "bad cleaner function result" unless
          cleaner_ids.all? {|id| id.is_a?(Fixnum) }

        row_proc = nil
        eline = 0

        begin
          res = parsed.each_with_index.map { |row, line|
            eline = line

            row_proc ||= RowProcessor.
            new(klass,
                row.respond_to?(:headers) ? row.headers : row.keys,
                dt,
                )
            # skip lines which are all nil
            next :blank if row.to_hash.values.none?

            row_proc.create_or_update(row)
          }
        rescue => exc
          raise Marty::DataImporterError.new(exc.to_s, [eline])
        end

        ids = {}

        # raise an error if record referenced more than once.
        res.each_with_index do
          |(op, id), line|
          raise Marty::DataImporterError.
            new("record referenced more than once", [ids[id], line]) if
            op != :blank && ids.member?(id) && !allow_dups

          ids[id] = line
        end

        begin
          # Validate affected rows if necessary
          klass.send(validation_function.to_sym, ids.keys) if
            validation_function
        rescue => exc
          raise Marty::DataImporterError.new(exc.to_s, [])
        end

        remainder_ids = cleaner_ids - ids.keys

        raise Marty::DataImporterError.
          new("Missing import data. " +
              "Please provide header line and at least one data line.", [1]) if
          ids.keys.compact.count == 0

        klass.delete(remainder_ids)
        res + remainder_ids.map {|id| [:clean, id]}
      end
    end
  end
end
