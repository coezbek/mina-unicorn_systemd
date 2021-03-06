require "mina/unicorn/version"

#
# The following tasks are for generating and setting up the systemd service which runs Unicorn
#
namespace :unicorn do
  
  set :unicorn_service_name,        -> { "unicorn-#{fetch(:application_name)}.service" }
  
  set :unicorn_system_or_user,      -> { "user" }

  set :unicorn_systemd_config_path, -> {    
    if is_unicorn_user_installation?
      "$HOME/.config/systemd/user/#{fetch :unicorn_service_name}" 
    else
      "/etc/systemd/system/#{fetch :unicorn_service_name}"
    end
  }
  
  set :nginx_socket_path,           -> { "#{fetch(:shared_path)}/unicorn.sock" }
  
  desc "Generate Unicorn systemd service template in the local repo to customize it"
  task :generate do
    run :local do
      
      target_path = File.expand_path("./config/deploy/templates/unicorn.service.erb")
      source_path = File.expand_path("../templates/unicorn.service.erb", __FILE__)
      
      if File.exist? target_path
        error! %(Unicorn service template already exists; please rm to continue: #{target_path})
      else
        command %(mkdir -p config/deploy/templates)
        command %(cp #{source_path} #{target_path})
      end
            
    end
  end
  
  desc "Setup Unicorn systemd service on the remote server (but doesn't start it)"
  task :setup do
  
    # Fetch these before elevation!
    username = fetch(:user)
    target_path = fetch :unicorn_systemd_config_path
    template = erb template_path

    unicorn_elevate do 
      run :remote do 

        comment %(Check for systemd on remote server)
        command %([[ `systemctl` =~ -\.mount ]] || { echo 'Systemd not found, but mina-unicorn_systemd needs it.'; exit 1; }) # From https://unix.stackexchange.com/a/164092

        if is_unicorn_user_installation?
          comment %(Check for libpam on remote server)
          command %(DEBIAN_FRONTEND=noninteractive apt -yqq install libpam-systemd)
      
          comment %(Enable linger for systemd --user)    
          command %(loginctl enable-linger #{username} || { echo 'Could not enable linger for user #{username} but mina-unicorn_systemd needs it.'; exit 1; }) 
        end  

        comment %(Installing unicorn systemd config file to #{target_path})
        command %(mkdir -p $(dirname #{target_path}))
        command %(echo '#{template}' > #{target_path})

        comment %(Reloading systemd configuration)
        command %(systemctl#{" --user" if is_unicorn_user_installation?} daemon-reload || { echo 'If this command fails in user mode then you likely have disabled UsePAM in your /etc/ssh/sshd_config which is needed'; exit 1; }) # https://superuser.com/a/1561345/32638

      end
    end
    
  end
  
  desc "Get the status of the Unicorn systemd service on the remote server"
  task :status do
    command command_systemd_raw("status")
  end
  
  %w(start stop restart enable disable).each { |verb| 
    desc "#{verb.capitalize} the Unicorn systemd service on the remote server"
    
    task verb.to_sym do
    
      if is_unicorn_user_installation?
        
        run :remote do 
          command_systemd verb
        end

      else
        
        unicorn_elevate do 
          run :remote do 
            command_systemd verb
          end
        end
      
      end
    
    end
    
  }
    
  # Returns the path to the template to use. Depending on whether the internal template was customized.
  def template_path
  
    custom_path = File.expand_path("./config/deploy/templates/unicorn.service.erb")
    original_path = File.expand_path("../templates/unicorn.service.erb", __FILE__)
    
    File.exist?(custom_path) ? custom_path : original_path
  end

  def is_unicorn_user_installation?
    case fetch(:unicorn_system_or_user)
    when "user" 
      true
    when "system"
      false
    else
      raise "Undefined unicorn_system_or_user value. Must be 'user' or 'system'."
    end
  end

  def command_systemd_raw verb
    return %(systemctl#{" --user" if is_unicorn_user_installation?} #{verb} #{fetch :unicorn_service_name})
  end

  # Execute the systemd verb action and if it fails print the error information
  def command_systemd verb
    c = %((#{command_systemd_raw(verb)} && #{command_systemd_raw("status")}) || journalctl #{" --user" if is_unicorn_user_installation?} --no-pager _SYSTEMD_INVOCATION_ID=`systemctl #{" --user" if is_unicorn_user_installation?} show -p InvocationID --value #{fetch :unicorn_service_name}`)

    comment c
    command c
  end
  
  def unicorn_elevate 

    user = fetch(:user)
    setup_user = fetch(:setup_user, user)
    if setup_user && setup_user != user
      comment %{Switching to setup_user (#{setup_user})}
      set :user, setup_user
      yield
      set :user, user
    else
      yield
    end
  
  end
  
  desc "Print Unicorn systemd service config expanded from the local template"
  task :print do
    run :local do
      command %(echo '#{erb template_path}')
    end
  end

  desc "Print current Unicorn systemd service config from remote"
  task :print_remote do
    unicorn_systemd_config_path = fetch :unicorn_systemd_config_path
    comment %(Printing content of #{unicorn_systemd_config_path} from remote server)
    command %(cat #{unicorn_systemd_config_path} || echo "Hello")
  end

end
