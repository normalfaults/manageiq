class Zone < ActiveRecord::Base
  DEFAULT_NTP_SERVERS = {:server => %w(0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org)}.freeze

  validates_presence_of   :name, :description
  validates_uniqueness_of :name

  serialize :settings, Hash

  belongs_to      :log_file_depot, :class_name => "FileDepot"
  alias_attribute :log_depot, :log_file_depot

  has_many :miq_servers
  has_many :active_miq_servers, :class_name => "MiqServer", :conditions => {:status => MiqServer::STATUSES_ACTIVE}
  has_many :ext_management_systems
  has_many :file_depots, :dependent => :destroy, :as => :resource
  has_many :vdi_farms
  has_many :miq_groups, :as => :resource
  has_many :miq_schedules, :dependent => :destroy
  has_many :storage_managers
  has_many :ldap_regions

  virtual_has_many :hosts,             :uses => {:ext_management_systems => :hosts}
  virtual_has_many :vms_and_templates, :uses => {:ext_management_systems => :vms_and_templates}

  include ReportableMixin

  before_destroy :check_zone_in_use_on_destroy
  after_save     :queue_ntp_reload_if_changed

  include AuthenticationMixin

  include Metric::CiMixin
  include AggregationMixin
  # Since we've overridden the implementation of methods from AggregationMixin,
  # we must also override the :uses portion of the virtual columns.
  override_aggregation_mixin_virtual_columns_uses(:all_hosts, :hosts)
  override_aggregation_mixin_virtual_columns_uses(:all_vms_and_templates, :vms_and_templates)

  def find_master_server
    self.active_miq_servers.select { |s| s.is_master? }.first
  end

  def self.seed
    MiqRegion.my_region.lock do
      unless self.exists?(:name => 'default')
        $log.info("MIQ(Zone.seed) Creating default zone...")
        self.create(:name => "default", :description => "Default Zone")
        $log.info("MIQ(Zone.seed) Creating default zone... Complete")
      end
    end
  end

  def miq_region
    MiqRegion.first(:conditions => {:region => self.region_id})
  end

  def ntp_settings
    # Return ntp settings if populated otherwise return the defaults  {:ntp => {:server => ['blah'], :timeout => 5}}
    return settings[:ntp] if settings.fetch_path(:ntp, :server).present?

    Zone::DEFAULT_NTP_SERVERS.dup
  end

  def assigned_roles
    self.miq_servers.collect { |s| s.assigned_roles }.flatten.uniq.compact
  end

  def role_active?(role_name)
    self.active_miq_servers.any? {|s| s.has_active_role?(role_name) }
  end

  def role_assigned?(role_name)
    self.active_miq_servers.any? {|s| s.has_assigned_role?(role_name) }
  end

  def active_role_names
    self.miq_servers.collect {|s| s.active_role_names}.flatten.uniq
  end

  def self.default_zone
    self.find_by_name("default")
  end

  # The zone to use when inserting a record into MiqQueue
  def self.determine_queue_zone(options)
    if options.key?(:zone)
      options[:zone] # return specified zone including nil (aka ANY zone)
    elsif options[:role] && ServerRole.regional_role?(options[:role])
      nil # ANY zone, will be limited by role
    else
      MiqServer.my_zone
    end
  end

  def synchronize_logs(*args)
    active_miq_servers.all.each { |s| s.synchronize_logs(*args) }
  end

  def last_log_sync_on
    self.miq_servers.inject(nil) do |d,s|
      last = s.last_log_sync_on
      d ||= last
      d = last if last && last > d
      d
    end
  end

  def log_collection_active?
    self.miq_servers.any? { |s| s.log_collection_active? }
  end

  def log_collection_active_recently?(since = nil)
    self.miq_servers.any? { |s| s.log_collection_active_recently?(since) }
  end

  def log_depot_uri
    get_log_depot_settings.try(:fetch_path, :uri)
  end

  def log_depot_configured?
    get_log_depot_settings
  end

  def get_log_depot_settings
    log_file_depot.try(:depot_hash)
  end

  def host_ids
    hosts.collect { |h| h.id }
  end

  def hosts
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :hosts).run
    self.ext_management_systems.collect { |e| e.hosts }.flatten
  end

  def non_clustered_hosts
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :hosts).run
    self.ext_management_systems.collect { |e| e.non_clustered_hosts }.flatten
  end

  def clustered_hosts
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :hosts).run
    self.ext_management_systems.collect { |e| e.clustered_hosts }.flatten
  end

  def ems_clusters
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :ems_clusters).run
    self.ext_management_systems.collect { |e| e.ems_clusters }.flatten
  end

  def ems_infras
    self.ext_management_systems.select { |e| e.kind_of? EmsInfra }
  end

  def ems_clouds
    self.ext_management_systems.select { |e| e.kind_of? EmsCloud }
  end

  def availability_zones
    ActiveRecord::Associations::Preloader.new(self.ems_clouds, :availability_zones).run
    self.ems_clouds.collect { |e| e.availability_zones }.flatten
  end

  def vms_without_availability_zone
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :vms).run
    self.ext_management_systems.collect do |e|
      e.kind_of?(EmsCloud) ? e.vms.select { |vm| vm.availability_zone.nil? } : []
    end.flatten
  end

  def vms_and_templates
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :vms_and_templates).run
    self.ext_management_systems.collect { |e| e.vms_and_templates }.flatten
  end

  def vms
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :vms).run
    self.ext_management_systems.collect { |e| e.vms }.flatten
  end

  def miq_templates
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => :miq_templates).run
    self.ext_management_systems.collect { |e| e.miq_templates }.flatten
  end

  def vm_or_template_ids
    vms_and_templates.collect { |v| v.id }
  end

  def vm_ids
    vms.collect { |v| v.id }
  end

  def miq_template_ids
    miq_templates.collect { |t| t.id }
  end

  def storages
    ActiveRecord::Associations::Preloader.new(self, :ext_management_systems => {:hosts => :storages}).run
    self.ext_management_systems.collect { |e| e.storages }.flatten.uniq
  end

  def miq_proxies
    ems_ids = self.ext_management_systems.collect {|e| e.id }
    MiqProxy.all(:include => :host, :conditions => ["hosts.ems_id in (?)", ems_ids])
  end

  def vdi_farms
    ems_ids = self.ext_management_systems.collect(&:id)
    VdiDesktopPool.joins(:ext_management_systems).where('ext_management_systems.id' => ems_ids).collect {|dp| dp.vdi_farm}.compact.uniq
  end

  # Used by AggregationMixin
  alias all_storages           storages
  alias all_hosts              hosts
  alias all_host_ids           host_ids
  alias all_vms_and_templates  vms_and_templates
  alias all_vm_or_template_ids vm_or_template_ids
  alias all_vms                vms
  alias all_vm_ids             vm_ids
  alias all_miq_templates      miq_templates
  alias all_miq_template_ids   miq_template_ids

  def display_name
    name
  end

  def active?
    miq_servers.any?(&:active?)
  end

  protected

  def check_zone_in_use_on_destroy
    raise "cannot delete default zone" if self.name == "default"
    raise "zone name '#{self.name}' is used by a server" unless self.miq_servers.blank?
  end

  private

  def queue_ntp_reload_if_changed
    return if settings_was[:ntp] == ntp_settings

    servers = active_miq_servers
    return if servers.blank?
    $log.info("MIQ(Zone#queue_ntp_reload) Zone: [#{name}], Queueing ntp_reload for [#{servers.length}] active_miq_servers, ids: #{servers.collect(&:id)}")

    servers.each do |s|
      MiqQueue.put(
        :class_name  => "MiqServer",
        :instance_id => s.id,
        :method_name => "ntp_reload",
        :args        => [ntp_settings],
        :server_guid => s.guid,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :zone        => name
      )
    end
  end
end
