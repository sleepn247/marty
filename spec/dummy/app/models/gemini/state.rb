class Gemini::State < ActiveRecord::Base
  extend Marty::Enum

  self.table_name_prefix = "gemini_"

  validates_presence_of :name, :full_name
  validates_uniqueness_of :name, :full_name

  delorean_fn :lookup, sig: 1 do
    |name|
    self.find_by_name(name)
  end

  def to_s
    name
  end

  # FIXME: prevent deletion/update
end
