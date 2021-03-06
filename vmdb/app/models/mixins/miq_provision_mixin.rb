module MiqProvisionMixin

  def tag_ids
    self.options[:vm_tags]
  end

  def tag_ids=(value)
    self.options[:vm_tags] = value
  end

  def register_automate_callback(callback_name, automate_uri)
    log_header = "MIQ(#{self.class.name}.register_automate_callback)"
    $log.info("#{log_header} Registering callback: [#{callback_name}] with Automate entry point: [#{automate_uri}]")
    self.options[:callbacks] ||= {}
    self.options[:callbacks][callback_name.to_sym] = automate_uri
    self.update_attribute(:options, self.options)
  end

  def set_vm_notes(notes)
    self.update_attribute(:options, self.options.merge(:vm_notes => notes))
  end

  def call_automate_event(event_name, continue_on_error = true)
    log_header = "MIQ(#{self.class.name}.call_automate_event)"
    begin
      $log.info("#{log_header} Raising event [#{event_name}] to Automate")
      ws = MiqAeEvent.raise_evm_event(event_name, self)
      $log.info("#{log_header} Raised  event [#{event_name}] to Automate")
      return ws
    rescue MiqAeException::Error => err
      message = "Error returned from #{event_name} event processing in Automate: #{err.message}"
      if continue_on_error
        $log.warn("#{log_header} [#{message}] encountered during provisioning - continuing")
      else
        $log.error("#{log_header} [#{message}] encountered during provisioning")
      end
      return nil
    end
  end

  def get_owner
    @owner ||= begin
      email = get_option(:owner_email)
      User.find(:first, :conditions => ["lower(email) = ?", email.downcase]) unless email.blank?
    end
  end

  def workflow(prov_options = options, flags = {})
    MiqProvisionWorkflow.class_for_source(source).new(prov_options, userid, flags)
  end

  def eligible_resources(rsc_type)
    log_header = "MIQ(#{self.class.name}.eligible_resources)"
    prov_options = options.dup
    prov_options[:placement_auto] = [false, 0]
    prov_wf = workflow(prov_options, :skip_dialog_load => true)

    klass = case rsc_type
      when :clusters                then EmsCluster
      when :resource_pools          then ResourcePool
      when :folders                 then EmsFolder
      when :hosts                   then Host
      when :storages                then Storage
      when :pxe_servers             then PxeServer
      when :pxe_images              then PxeImage
      when :windows_images          then WindowsImage
      when :customization_templates then CustomizationTemplate
      when :iso_images              then IsoImage
      else nil
    end
    raise MiqException::MiqProvisionError, "Unsupported resource type <#{rsc_type}> passed to eligible_resources for provisioning." if klass.nil?
    raise MiqException::MiqProvisionError, "Provision workflow does not contain the expected method <allowed_#{rsc_type}>" unless prov_wf.respond_to?("allowed_#{rsc_type}")

    result = prov_wf.send("allowed_#{rsc_type}")
    result = result.collect {|rsc| eligible_resource_lookup(klass, rsc)}

    data = result.collect {|rsc| "#{rsc.id}:#{rsc.name}"}
    $log.info("#{log_header} returning <#{rsc_type}>:<#{data.join(', ')}>")
    return result
  end

  # Helper method to determines the ID for a resource and load the active-record object.
  # The rsc_data will either be in the form of a HashStruct with an 'id' property or as an array
  # in the format [id, display_name].  Additionally, some IDs can contain model metadata in the
  # form "class_name::id".
  def eligible_resource_lookup(klass, rsc_data)
    ci_id = rsc_data.kind_of?(Array) ? rsc_data.first : rsc_data.id
    ci_id = ci_id.split("::").last if ci_id.to_s.include?("::")
    klass.find_by_id(ci_id)
  end
  private :eligible_resource_lookup

  def set_resource(rsc, options={})
    log_header = "MIQ(#{self.class.name}.set_resource)"
    return if rsc.nil?
    rsc_class = $1 if rsc.class.base_class.name =~ /::MiqAeService(.*)/

    rsc_type, key = case rsc_class
            when "Host"         then [:hosts,          :placement_host_name]
            when "Storage"      then [:storages,       :placement_ds_name]
            when "EmsCluster"   then [:clusters,       :placement_cluster_name]
            when "ResourcePool" then [:resource_pools, :placement_rp_name]
            when "EmsFolder"    then [:folders,        :placement_folder_name]
            when "PxeServer"    then [:pxe_servers,    :pxe_server_id]
            when "PxeImage"     then [:pxe_images,     :pxe_image_id]
            when "WindowsImage" then [:windows_images, :pxe_image_id]
            when "CustomizationTemplate" then [:customization_templates, :customization_template_id]
            when "IsoImage"     then [:iso_images,     :iso_image_id]
            else nil
            end

    raise "Unsupported resource type <#{rsc.class.base_class.name}> passed to set_resource for provisioning." if rsc_type.nil?
    rsc_id = rsc.attributes['id']
    result = self.eligible_resources(rsc_type).any? {|r| r.id == rsc_id}
    raise "Resource <#{rsc_class}> <#{rsc_id}:#{rsc.name}> is not an eligible resource for this provisioning instance." if result == false

    value = [rsc_id, rsc.name]
    value[0] = "#{rsc_class}::#{value.first}" if key == :pxe_image_id
    $log.info("#{log_header} option <#{key}> being set to <#{value.inspect}>")
    self.options[key] = value

    post_customization_templates(rsc_id) if rsc_type == :customization_templates

    self.update_attribute(:options, self.options)
  end

  def post_customization_templates(template_id)
    self.options[:customization_template_script] = CustomizationTemplate.where(:id => template_id).first.try(:script)
  end

  def set_folder(folder)
    return nil  if folder.blank?
    return self.set_resource(folder) if folder.kind_of?(MiqAeMethodService::MiqAeServiceEmsFolder)

    result = nil
    begin
      if folder.kind_of?(Array) && folder.length==2 && folder.first.kind_of?(Integer)
        result = EmsFolder.find_by_id(folder.first)
        result = [result.id, result.name] unless result.nil?
      else
        find_path = folder.to_miq_a.join('/')
        result = self.get_folder_paths.detect {|key, path| path.casecmp(find_path) == 0}
      end
      self.update_attribute(:options, self.options.merge({:placement_folder_name => result})) unless result.nil?
    rescue => err
      $log.error "MIQ(MiqProvision.set_folder) #{err}\n#{err.backtrace.join("\n")}"
    end
    return result
  end

  def get_folder_paths
    # If the host is selected we need to limit the folders returned based on the data-center
    # the host is in.  Otherwise we return all folders in all data-centers.
    host = get_option(:placement_host_name)
    if host.nil?
      self.vm_template.ext_management_system.get_folder_paths()
    else
      dest_host = Host.find(host)
      self.vm_template.ext_management_system.get_folder_paths(dest_host.owning_datacenter)
    end
  end

  def get_source_vm
    vm_id = get_option(:src_vm_id)
    raise "Source VM not provided" if vm_id.nil?
    svm = VmOrTemplate.find_by_id(vm_id)
    raise "Unable to find VM with Id: [#{vm_id}]" if svm.nil?
    return svm
  end

  def get_source_name
    self.get_option_last(:src_vm_id)
  end

  def get_new_disks()
    new_disks_req = self.options[:disk_scsi]
    return [] if new_disks_req.blank?

    svm = get_source_vm
    scsi_idx = svm.hardware.disks.collect {|d| d.location if d.controller_type == "scsi"}.compact

    # Add any disk that does not already exist at the same location
    new_disks_req.reject {|d| scsi_idx.include?("#{d[:bus]}:#{d[:pos]}")}
  end

  def set_customization_spec(custom_spec_name, override=false)
    log_header = "MIQ(#{self.class.name}.set_customization_spec)"

    if !self.source.ext_management_system.kind_of?(EmsVmware)
      $log.info "#{log_header} Specifying a Customization spec is not valid for provision type #{self.class.name}.  Spec name: <#{custom_spec_name.inspect}>"
      return false
    end

    if custom_spec_name.nil?
      disable_customization_spec
    else
      options = self.options.dup
      prov_wf = workflow
      options[:sysprep_enabled]       = ['fields', 'Specification']
      prov_wf.init_from_dialog(options, self.userid)
      prov_wf.get_all_dialogs
      prov_wf.allowed_customization_specs
      prov_wf.get_timezones
      prov_wf.refresh_field_values(options, self.userid)
      custom_spec = prov_wf.allowed_customization_specs.detect {|cs| cs.name == custom_spec_name}
      raise MiqException::MiqProvisionError, "Customization Specification [#{custom_spec_name}] does not exist." if custom_spec.nil?

      options[:sysprep_custom_spec]   = [custom_spec.id, custom_spec.name]
      override_value = override == false ? [false, 0] : [true, 0]
      options[:sysprep_spec_override] = override_value
      # Call refresh_field_values a second time so it recognizes the config change
      # and loads the defaults the customization spec settings
      prov_wf.refresh_field_values(options, self.userid)

      self.options.keys.each do |key|
        v_old = self.options[key]
        v_new = options[key]
        $log.info "#{log_header} option <#{key}> was changed from <#{v_old.inspect}> to <#{v_new.inspect}>" unless v_old == v_new
      end

      self.update_attribute(:options, options)
    end

    return true
  end

  def disable_customization_spec
    self.options[:sysprep_enabled] = ['disabled', '(Do not customize)']
    self.update_attribute(:options, self.options)
  end

  def vdi_farm
    return nil unless self.get_option(:vdi_enabled) == true
    return VdiFarm.find_by_id(self.get_option(:vdi_farm))
  end

  def target_type
    return 'template' if self.provision_type == 'clone_to_template'
    return 'vm'
  end

  def source_type
    self.vm_template.kind_of?(MiqTemplate) ? 'template' : 'vm'
  end

  def set_nic_settings(idx, nic_hash, value=nil)
    if idx.to_i > 0
      self.set_options_config_array(:nic_settings, idx, nic_hash, value)
    else
      # if the index is 0 then we need to merge the hash directly into the options hash
      nic_hash.kind_of?(Hash) ? self.options.merge!(nic_hash) : self.options[nic_hash] = value
      self.update_attribute(:options, self.options)
    end
  end

  def set_network_adapter(idx, net_hash, value=nil)
    self.set_options_config_array(:networks, idx, net_hash, value)
  end

  def set_options_config_array(key, idx, hash, value=nil)
    idx = idx.to_i
    items = self.options[key] || []
    items[idx] = {} if items[idx].nil?
    hash.kind_of?(Hash) ? items[idx].merge!(hash) : items[idx][hash] = value
    self.options[key] = items
    self.update_attribute(:options, self.options)
  end

  def request_options
    skip_keys = [:vm_tags]
    self.options.collect do |k,v|
      if skip_keys.include?(k)
        nil
      elsif v.kind_of?(Array)
        if v.length == 2
          format_web_service_property(k, v[0])
        else
          nil
        end
      elsif v.kind_of?(Hash)
        nil
      else
        format_web_service_property(k, v)
      end
    end.compact
  end

  def format_web_service_property(key, value)
    return nil if value.kind_of?(Hash)
    return nil if value.blank?
    value = value.iso8601 if value.kind_of?(Time)
    {:key => key.to_s, :value => value.to_s}
  end
end
