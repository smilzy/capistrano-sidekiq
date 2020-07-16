git_plugin = self

namespace :sidekiq do
  desc 'Quiet sidekiq (stop fetching new tasks from Redis)'
  task :quiet do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        if fetch(:sidekiq_service_unit_user) == :system
          execute :sudo, :systemctl, "reload", fetch(:sidekiq_service_unit_name), raise_on_non_zero_exit: false
        else
          execute :systemctl, "--user", "reload", fetch(:sidekiq_service_unit_name), raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc 'Stop sidekiq (graceful shutdown within timeout, put unfinished tasks back to Redis)'
  task :stop do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        if fetch(:sidekiq_service_unit_user) == :system
          execute :sudo, :systemctl, "stop", fetch(:sidekiq_service_unit_name)
        else
          execute :systemctl, "--user", "stop", fetch(:sidekiq_service_unit_name)
        end
      end
    end
  end

  desc 'Start sidekiq'
  task :start do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        if fetch(:sidekiq_service_unit_user) == :system
          execute :sudo, :systemctl, 'start', fetch(:sidekiq_service_unit_name)
        else
          execute :systemctl, '--user', 'start', fetch(:sidekiq_service_unit_name)
        end
      end
    end
  end

  desc 'Install systemd sidekiq service'
  task :install do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        # git_plugin.create_systemd_template
        git_plugin.create_all_systemd_templates
        if fetch(:sidekiq_service_unit_user) == :system
          execute :sudo, :systemctl, "enable", fetch(:sidekiq_service_unit_name)
        else
          execute :systemctl, "--user", "enable", fetch(:sidekiq_service_unit_name)
          execute :loginctl, "enable-linger", fetch(:sidekiq_lingering_user) if fetch(:sidekiq_enable_lingering)
        end
      end
    end
  end

  desc 'UnInstall systemd sidekiq service'
  task :uninstall do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        if fetch(:sidekiq_service_unit_user) == :system
          execute :sudo, :systemctl, "disable", fetch(:sidekiq_service_unit_name)
        else
          execute :systemctl, "--user", "disable", fetch(:sidekiq_service_unit_name)
        end
        execute :rm, '-f', File.join(fetch(:service_unit_path, fetch_systemd_unit_path), fetch(:sidekiq_service_unit_name))
      end
    end
  end

  desc 'Generate service_locally'
  task :generate_service_locally do
    run_locally do
      File.write('sidekiq', git_plugin.compiled_template)
    end
  end

  def fetch_systemd_unit_path
    if fetch(:sidekiq_service_unit_user) == :system
      # if the path is not standard `set :service_unit_path`
      "/etc/systemd/system/"
    else
      home_dir = backend.capture :pwd
      File.join(home_dir, ".config", "systemd", "user")
    end
  end

  def compiled_template(index: nil)
    search_paths = [
      File.expand_path(
          File.join(*%w[.. .. .. generators capistrano sidekiq systemd templates sidekiq.service.capistrano.erb]),
          __FILE__
      ),
    ]
    template_path = search_paths.detect { |path| File.file?(path) }
    template = File.read(template_path)
    ERB.new(template).result(binding)
  end

  def process_list
    @process_list ||= pid_files.each_with_index do |pid_file, idx|
      within release_path do
        yield(pid_file, idx)
      end
    end
  end

  def sidekiq_processes
    @sidekiq_processes ||= [].tap do |array|
      process_options = fetch(:sidekiq_options_per_process)

      process_options&.each do |option|
        array << option
      end
    end
  end

  def create_all_systemd_templates
    sidekiq_processes.each.with_index(0) do |_object, index|
      create_systemd_template(index: index)
    end
  end

  def create_systemd_template(index: nil)
    ctemplate = compiled_template(index: index)
    systemd_path = fetch(:service_unit_path, fetch_systemd_unit_path)
    filename =     [(fetch :sidekiq_service_unit_name), index].join('---')

    if fetch(:sidekiq_service_unit_user) == :user
      backend.execute :mkdir, "-p", systemd_path
    end
    backend.upload!(
        StringIO.new(ctemplate),
        "/tmp/#{filename}.service"
    )
    if fetch(:sidekiq_service_unit_user) == :system
      backend.execute :sudo, :mv, "/tmp/#{filename}.service", "#{systemd_path}/#{filename}.service"
      backend.execute :sudo, :systemctl, "daemon-reload"
    else
      backend.execute :mv, "/tmp/#{filename}.service", "#{systemd_path}/#{filename}.service"
      backend.execute :systemctl, "--user", "daemon-reload"
    end
  end

  def switch_user(role)
    su_user = sidekiq_user
    if su_user != role.user
      yield
    else
      backend.as su_user do
        yield
      end
    end
  end

  def sidekiq_user
    fetch(:sidekiq_user, fetch(:run_as))
  end
end
