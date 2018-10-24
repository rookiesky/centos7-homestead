# Main Homestead Class
class Homestead
  def self.configure(config, settings)
    # Set The VM Provider
    ENV['VAGRANT_DEFAULT_PROVIDER'] = settings['provider'] ||= 'virtualbox'

    # Configure Local Variable To Access Scripts From Remote Location
    script_dir = File.dirname(__FILE__)

    # Allow SSH Agent Forward from The Box
    config.ssh.forward_agent = true

    # Configure The Box
    config.vm.define settings['name'] ||= 'lamp'
    config.vm.box = settings['box'] ||= 'centos/7'
    config.vm.box_version = settings['version'] ||= '>= 6.0'
    config.vm.hostname = settings['hostname'] ||= 'homestead'

    # Configure A Private Network IP
    if settings['ip'] != 'autonetwork'
      config.vm.network :private_network, ip: settings['ip'] ||= '192.168.12.12'
    else
      config.vm.network :private_network, ip: '0.0.0.0', auto_network: true
    end

    # Configure Additional Networks
    if settings.has_key?('networks')
      settings['networks'].each do |network|
        config.vm.network network['type'], ip: network['ip'], bridge: network['bridge'] ||= nil, netmask: network['netmask'] ||= '255.255.255.0'
      end
    end

    # Configure A Few VirtualBox Settings
    config.vm.provider 'virtualbox' do |vb|
      vb.name = settings['name'] ||= 'lamp'
      vb.customize ['modifyvm', :id, '--memory', settings['memory'] ||= '2048']
      vb.customize ['modifyvm', :id, '--cpus', settings['cpus'] ||= '1']
      vb.customize ['modifyvm', :id, '--natdnsproxy1', 'on']
      vb.customize ['modifyvm', :id, '--natdnshostresolver1', settings['natdnshostresolver'] ||= 'on']
      #vb.customize ['modifyvm', :id, '--ostype', 'Ubuntu_64']
      if settings.has_key?('gui') && settings['gui']
        vb.gui = true
      end
    end

    # Override Default SSH port on the host
    if settings.has_key?('default_ssh_port')
      config.vm.network :forwarded_port, guest: 22, host: settings['default_ssh_port'], auto_correct: false, id: "ssh"
    end

    # Configure A Few VMware Settings
    ['vmware_fusion', 'vmware_workstation'].each do |vmware|
      config.vm.provider vmware do |v|
        v.vmx['displayName'] = settings['name'] ||= 'lamp'
        v.vmx['memsize'] = settings['memory'] ||= 2048
        v.vmx['numvcpus'] = settings['cpus'] ||= 1
        v.vmx['guestOS'] = 'centos-64'
        if settings.has_key?('gui') && settings['gui']
          v.gui = true
        end
      end
    end

    # Configure A Few Parallels Settings
    config.vm.provider 'parallels' do |v|
      v.name = settings['name'] ||= 'lamp'
      v.update_guest_tools = settings['update_parallels_tools'] ||= false
      v.memory = settings['memory'] ||= 2048
      v.cpus = settings['cpus'] ||= 1
    end

    # Standardize Ports Naming Schema
    if settings.has_key?('ports')
      settings['ports'].each do |port|
        port['guest'] ||= port['to']
        port['host'] ||= port['send']
        port['protocol'] ||= 'tcp'
      end
    else
      settings['ports'] = []
    end

    # Default Port Forwarding
    default_ports = {
      80 => 8000,
      443 => 44300,
      3306 => 33060,
      4040 => 4040,
      5432 => 54320,
      8025 => 8025,
      27017 => 27017
    }

    # Use Default Port Forwarding Unless Overridden
    unless settings.has_key?('default_ports') && settings['default_ports'] == false
      default_ports.each do |guest, host|
        unless settings['ports'].any? { |mapping| mapping['guest'] == guest }
          config.vm.network 'forwarded_port', guest: guest, host: host, auto_correct: true
        end
      end
    end

    # Add Custom Ports From Configuration
    if settings.has_key?('ports')
      settings['ports'].each do |port|
        config.vm.network 'forwarded_port', guest: port['guest'], host: port['host'], protocol: port['protocol'], auto_correct: true
      end
    end

    # Configure The Public Key For SSH Access
    if settings.include? 'authorize'
      if File.exist? File.expand_path(settings['authorize'])
        config.vm.provision 'shell' do |s|
          s.inline = "echo $1 | grep -xq \"$1\" /home/vagrant/.ssh/authorized_keys || echo \"\n$1\" | tee -a /home/vagrant/.ssh/authorized_keys"
          s.args = [File.read(File.expand_path(settings['authorize']))]
        end
      end
    end

    # Copy The SSH Private Keys To The Box
    if settings.include? 'keys'
      if settings['keys'].to_s.length.zero?
        puts 'Check your Homestead.yaml file, you have no private key(s) specified.'
        exit
      end
      settings['keys'].each do |key|
        if File.exist? File.expand_path(key)
          config.vm.provision 'shell' do |s|
            s.privileged = false
            s.inline = "echo \"$1\" > /home/vagrant/.ssh/$2 && chmod 600 /home/vagrant/.ssh/$2"
            s.args = [File.read(File.expand_path(key)), key.split('/').last]
          end
        else
          puts 'Check your Homestead.yaml file, the path to your private key does not exist.'
          exit
        end
      end
    end

    # Copy User Files Over to VM
    if settings.include? 'copy'
      settings['copy'].each do |file|
        config.vm.provision 'file' do |f|
          f.source = File.expand_path(file['from'])
          f.destination = file['to'].chomp('/') + '/' + file['from'].split('/').last
        end
      end
    end

    # Register All Of The Configured Shared Folders
    if settings.include? 'folders'
      settings['folders'].each do |folder|
        if File.exist? File.expand_path(folder['map'])
          mount_opts = []

          if folder['type'] == 'nfs'
            mount_opts = folder['mount_options'] ? folder['mount_options'] : ['actimeo=1', 'nolock']
          elsif folder['type'] == 'smb'
            mount_opts = folder['mount_options'] ? folder['mount_options'] : ['vers=3.02', 'mfsymlinks']
          end

          # For b/w compatibility keep separate 'mount_opts', but merge with options
          options = (folder['options'] || {}).merge({ mount_options: mount_opts })

          # Double-splat (**) operator only works with symbol keys, so convert
          options.keys.each{|k| options[k.to_sym] = options.delete(k) }

          config.vm.synced_folder folder['map'], folder['to'], owner: folder['owner'], group:folder['group'], type: folder['type'] ||= nil, **options

          # Bindfs support to fix shared folder (NFS) permission issue on Mac
          if folder['type'] == 'nfs' && Vagrant.has_plugin?('vagrant-bindfs')
            config.bindfs.bind_folder folder['to'], folder['to']
          end
        else
          config.vm.provision 'shell' do |s|
            s.inline = ">&2 echo \"Unable to mount one of your folders. Please check your folders in Homestead.yaml\""
          end
        end
      end
    end
 
  
    # Configure Blackfire.io
    if settings.has_key?('blackfire')
      config.vm.provision 'shell' do |s|
        s.path = script_dir + '/blackfire.sh'
        s.args = [
          settings['blackfire'][0]['id'],
          settings['blackfire'][0]['token'],
          settings['blackfire'][0]['client-id'],
          settings['blackfire'][0]['client-token']
        ]
      end
    end

    # Add config file for ngrok
    config.vm.provision 'shell' do |s|
      s.path = script_dir + '/create-ngrok.sh'
      s.args = [settings['ip']]
      s.privileged = false
    end

    if settings.has_key?('backup') && settings['backup'] && (Vagrant::VERSION >= '2.1.0' || Vagrant.has_plugin('vagrant-triggers'))
      dir_prefix = '/vagrant/'
      settings['databases'].each do |database|
        Homestead.backup_mysql(database, "#{dir_prefix}/mysql_backup", config)
        Homestead.backup_postgres(database, "#{dir_prefix}/postgres_backup", config)
      end
    end

    # Turn off CFQ scheduler idling https://github.com/laravel/homestead/issues/896
    if settings.has_key?('disable_cfq')
      config.vm.provision 'shell' do |s|
        s.inline = 'sudo echo 0 >/sys/block/sda/queue/iosched/slice_idle'
      end
      config.vm.provision 'shell' do |s|
        s.inline = 'sudo echo 0 >/sys/block/sda/queue/iosched/group_idle'
      end
    end
  end

  def self.backup_mysql(database, dir, config)
    now = Time.now.strftime("%Y%m%d%H%M")
    config.trigger.before :destroy do |trigger|
      trigger.warn = "Backing up mysql database #{database}..."
      trigger.run_remote = { inline: "mkdir -p #{dir} && mysqldump #{database} > #{dir}/#{database}-#{now}.sql" }
    end
  end

  def self.backup_postgres(database, dir, config)
    now = Time.now.strftime("%Y%m%d%H%M")
    config.trigger.before :destroy do |trigger|
      trigger.warn = "Backing up postgres database #{database}..."
      trigger.run_remote = { inline: "mkdir -p #{dir} && echo localhost:5432:#{database}:homestead:secret > ~/.pgpass && chmod 600 ~/.pgpass && pg_dump -U homestead -h localhost #{database} > #{dir}/#{database}-#{now}.sql" }
    end
  end
end
