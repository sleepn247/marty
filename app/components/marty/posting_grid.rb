class Marty::PostingGrid < Marty::Grid
  has_marty_permissions read: :any,
                        delete: :any # delete is hijacked for a select

  def configure(c)
    super

    c.header             = false
    c.model              = "Marty::Posting"
    c.columns            = [:name, :created_dt, :user__name, :comment]
    c.multi_select       = false
    c.data_store.sorters = {property: :created_dt, direction: 'DESC'}
  end

  # hijacking delete button
  action :del do |a|
    a.text      = "Select"
    a.tooltip   = "Select"
    a.icon      = :time_go
    a.disabled  = true
  end

  js_configure do |c|
    c.init_component = <<-JS
    function() {
       this.callParent();
       this.getSelectionModel().on('selectionchange', function(selModel) {
          this.actions.detail &&
          this.actions.detail.setDisabled(!selModel.hasSelection());
       }, this);

       var me = this;
       me.getView().on('itemkeydown', function(view, record, item, index, e) {
          if (e.getKey() === e.SPACE) {
             record_id = me.getSelectionModel().selected.first().getId();
             me.getView().fireEvent('itemclick', me, record);
             me.serverDetail({record_id: record_id});
             var rowIndex = me.find('id', record.getId());
             me.getView().select(rowIndex);
          }
       });
    }
    JS

    c.detail = <<-JS
    function() {
       record_id = this.getSelectionModel().selected.first().getId();
       this.serverDetail({record_id: record_id});
    }
    JS

    c.show_detail = <<-JS
    function(details) {
      Ext.create('Ext.Window', {
        height:         150,
        minWidth:       250,
        autoWidth:      true,
        modal:          true,
        autoScroll:     true,
        html:           details,
        title:          "Posting Details"
     }).show();
    }
    JS

    c.on_del = <<-JS
      function() {
        var records = [];
        var me = this;
        me.getSelectionModel().selected.each(function(r) {
           records.push(r.getId());
        }, me);

        // find the root component (main application)
        var main_app = me;
        while (1) {
          var p = main_app.netzkeGetParentComponent();
          if (!p) { break; }
          main_app = p;
        }

        // assumes main_app has serverSelectPosting method
        main_app.serverSelectPosting(records);
      }
      JS
  end

  def default_bbar
    [:del, :detail]
  end

  action :detail do |a|
    a.text      = "Detail"
    a.icon      = :application_view_detail
    a.handler   = :detail
    a.disabled  = true
  end

  endpoint :server_detail do |params, this|
    record_id = params[:record_id]

    # Prepare an HTML popup with session details such that the
    # contents can be easily pasted into a spreadsheet.

    pt = Marty::Posting.find_by_id(record_id)

    dt = pt.created_dt.to_s == 'Infinity' ? '---' :
      pt.created_dt.strftime('%Y-%m-%d %I:%M %p')

    html =
      "<b>Name:</b>\t#{pt.name}<br/>" +
      "<b>Date/Time:</b>\t#{dt}<br/>" +
      "<b>User:</b>\t#{pt.user.name}<br/>" +
      "<b>Comment:</b>\t#{pt.comment}"

    this.show_detail html
  end

  column :name do |c|
    c.flex      = 1
  end

  column :created_dt do |c|
    c.text      = "Date/Time"
    c.format    = "Y-m-d H:i"
    c.hidden    = true
  end

  column :user__name do |c|
    c.width     = 100
  end

  column :comment do |c|
    c.width     = 100
  end

end

PostingGrid = Marty::PostingGrid
