module MyCommand
  def commit_all(message)
    @generator.git(add: ".")
    @generator.git(commit: "-m '#{message}'")
  end

  def initial_commit
    message = 'rails new'
    message += "\n\n"
    message += "---options---\n"
    @options.each do |k, v|
      next if k.to_s == "ruby"
      message += "#{k}: #{v}\n"
    end
    message += "---options---"

    commit_all(message)
  end

  def readme
    @generator.remove_file('README.md')
    @generator.create_file('README.md', <<~README)
      # 悪い火星人の技術を真似してみる
       + [Terraforming Rails](https://github.com/evilmartians/terraforming-rails)
       + [dockerdev](https://github.com/evilmartians/terraforming-rails/tree/master/examples/dockerdev)

      ## Provision
      ```sh
      dip provision
      ```
    README
    commit_all('readme')
  end
end

module AddMarginalia
  def add_marginalia
    @generator.gem('marginalia')
    @generator.run("bundle install")
    @generator.initializer('marginalia.rb', <<~RUBY)
      # frozen_string_literal: true
      require 'marginalia'
      Marginalia::Comment.components = %i(application controller_with_namespace action job)
    RUBY
    commit_all('add marginalia')
  end
end

module Dockerdev
  def dockerdev
    t = Template.new(app_name, @options)
    @generator.create_file('dip.yml', t.dip_yml)
    @generator.create_file('docker-compose.yml', t.docker_compose_yml)
    @generator.create_file('.dockerdev/app/Dockerfile', t.dockerfile)
    @generator.create_file('.dockerdev/app/Aptfile', t.apt_file)
    @generator.gem('sidekiq')
    @generator.create_file('config/sidekiq.yml', <<~SIDEKIQ)
      :concurrency: 5
      :queues:
        - default
    SIDEKIQ
    @generator.run('bundle install')

    @generator.environment(<<~RUBY)
      config.active_job.queue_adapter = :sidekiq
    RUBY

    @generator.route(<<~ROUTE)
      if Rails.env.development?
        require("sidekiq/web")
        mount Sidekiq::Web => "/sidekiq"
      end
    ROUTE
    commit_all('dockerdev')
  end

  class Template
    def initialize(app_name, options)
      @app_name = app_name
      @options = options
      p db_client
    end

    def dip_yml
      <<~DIP
        version: '4.1'

        environment:
          RAILS_ENV: development

        compose:
          files:
            - docker-compose.yml

        interaction:
          sh:
            description: Open a Bash shell within a Rails container (with dependencies up)
            service: runner
            command: /bin/bash

          bash:
            description: Run an arbitrary script within a container (or open a shell without deps)
            service: runner
            command: /bin/bash
            compose_run_options: [no-deps]

          bundle:
            description: Run Bundler commands
            service: runner
            command: bundle
            compose_run_options: [no-deps]

          rake:
            description: Run Rake commands
            service: runner
            command: bundle exec rake

          rails:
            description: Run Rails commands
            service: runner
            command: bundle exec rails
            subcommands:
              s:
                description: Run Rails server available at http://localhost:3000
                service: rails
                compose:
                  run_options: [service-ports, use-aliases]

          yarn:
            description: Run Yarn commands
            service: runner
            command: yarn
            compose_run_options: [no-deps]

          test:
            description: Run Rails tests
            service: runner
            environment:
              RAILS_ENV: test
            command: bundle exec rails test

          rubocop:
            description: Run Rubocop
            service: runner
            command: bundle exec rubocop
            compose_run_options: [no-deps]

          'redis-cli':
            description: Run Redis console
            service: redis
            command: redis-cli -h redis

#{db_client}
        provision:
          - dip compose down --volumes
          - dip compose up -d redis #{db_name}
          - dip bundle install
          - dip yarn install
          - dip rake db:setup
      DIP
    end

    def db_client
      case @options[:database]
      when "postgresql"
        <<-PSQL
          psql:
            description: Run psql console
            service: postgres
            command: psql -h postgres -U postgres -d #{@app_name}_development

        PSQL
      when "mysql"
        <<-MSQL
          mysql:
            description: Run mysql
            service: mysql
            command: mysql -h mysql -u root -U #{@app_name}_development -p

        MSQL
      end
    end

    def dockerfile
      <<~DOCKER
        ARG RUBY_VERSION
        FROM ruby:$RUBY_VERSION-slim-buster

        ARG PG_MAJOR
        ARG NODE_MAJOR
        ARG BUNDLER_VERSION
        ARG YARN_VERSION

        # Common dependencies
        RUN apt-get update -qq \\
          && DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \\
            build-essential \\
            gnupg2 \\
            curl \\
            less \\
            git \\
          && apt-get clean \\
          && rm -rf /var/cache/apt/archives/* \\
          && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \\
          && truncate -s 0 /var/log/*log

        # Add PostgreSQL to sources list
        RUN curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \\
          && echo 'deb http://apt.postgresql.org/pub/repos/apt/ buster-pgdg main' $PG_MAJOR > /etc/apt/sources.list.d/pgdg.list

        # Add NodeJS to sources list
        RUN curl -sL https://deb.nodesource.com/setup_$NODE_MAJOR.x | bash -

        # Add Yarn to the sources list
        RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \\
          && echo 'deb http://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list

        # Install dependencies
        COPY .dockerdev/app/Aptfile /tmp/Aptfile
        RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade && \\
          DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \\ #{ lib_db_and_client }
            nodejs \\
            yarn=$YARN_VERSION-1 \\
            $(cat /tmp/Aptfile | xargs) && \\
            apt-get clean && \\
            rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \\
            truncate -s 0 /var/log/*log

        # Configure bundler
        ENV LANG=C.UTF-8 \\
          BUNDLE_JOBS=4 \\
          BUNDLE_RETRY=3
        RUN gem update --system && \\
            rm /usr/local/lib/ruby/gems/*/specifications/default/bundler-*.gemspec && \\
            gem uninstall bundler && \\
            gem install bundler -v $BUNDLER_VERSION

        RUN mkdir -p /app

        WORKDIR /app
      DOCKER
    end

    def lib_db_and_client
      case @options[:database]
      when "postgresql"
        "\nlibpq-dev postgresql-client-$PG_MAJOR \\"
      when "mysql"
        "\nlibmariadb-dev mariadb-client \\"
      end
    end

    def apt_file
      <<~APT
        vim
      APT
    end

    def docker_compose_yml
      <<~DC
        version: '3.4'

        x-app: &app
          build:
            context: .
            dockerfile: ./.dockerdev/app/Dockerfile
            args:
              RUBY_VERSION: '#{RUBY_VERSION}'
              PG_MAJOR: '12'
              NODE_MAJOR: '12'
              YARN_VERSION: '1.22.5'
              BUNDLER_VERSION: '2.1.4'
          environment: &env
            NODE_ENV: development
            RAILS_ENV: ${RAILS_ENV:-development}
          image: #{@app_name}_sample
          tmpfs:
            - /tmp

        x-backend: &backend
          <<: *app
          stdin_open: true
          tty: true
          volumes:
            - .:/app:cached
            - rails_cache:/app/tmp/cache
            - bundle:/usr/local/bundle
            - node_modules:/app/node_modules
            - packs:/app/public/packs
          environment:
            <<: *env
            DATABASE_URL: #{db_url}
            BOOTSNAP_CACHE_DIR: /usr/local/bundle/_bootsnap
            WEBPACKER_DEV_SERVER_HOST: webpacker
            HISTFILE: /app/log/.bash_history
            EDITOR: vi
            REDIS_URL: redis://redis:6379
          depends_on:
            - #{db_name}
            - redis

        services:
          runner:
            <<: *backend
            command: /bin/bash
            ports:
              - '3000:3000'
              - '3002:3002'

          rails:
            <<: *backend
            command: bundle exec rails server -b 0.0.0.0
            ports:
              - '3000:3000'

#{db_container}

          webpacker:
            <<: *backend
            command: bundle exec ./bin/webpack-dev-server
            ports:
              - '3035:3035'
            volumes:
              - .:/app:cached
              - bundle:/usr/local/bundle
              - node_modules:/app/node_modules
              - packs:/app/public/packs
            environment:
              <<: *env
              WEBPACKER_DEV_SERVER_HOST: 0.0.0.0

          redis:
            image: redis:6.0
            volumes:
              - redis:/data
            ports:
              - 6379
            healthcheck:
              test: redis-cli ping
              interval: 1s
              timeout: 3s
              retries: 30

          sidekiq:
            <<: *backend
            command: bundle exec sidekiq -C config/sidekiq.yml

        volumes:
          bundle:
          node_modules:
          packs:
          db:
          rails_cache:
          redis:
      DC
    end

    def db_name
      case @options[:database]
      when "postgresql"
        "postgres"
      when "mysql"
        "mysql"
      end
    end

    def db_container
      case @options[:database]
      when "postgresql"
        <<-PSQL
          postgres:
            image: postgres:12
            command: postgres -c log_statement=all
            volumes:
              - db:/var/lib/postgresql/data
              - ./log:/root/log:cached
            environment:
              PSQL_HISTFILE: /root/log/.psql_history
              POSTGRES_PASSWORD: password
            ports:
              - 5432
            healthcheck:
              test: pg_isready -U postgres -h 127.0.0.1
              interval: 5s
        PSQL
      when "mysql"
        <<-MYSQL
          mysql:
            image: mysql:8.0
            volumes:
              - db:/var/lib/mysql
            command: --default-authentication-plugin=mysql_native_password
            environment:
              MYSQL_ROOT_PASSWORD: password
            ports:
              - 3306
            healthcheck:
              test: mysqladmin ping -h localhost
              interval: 5s
        MYSQL
      end
    end

    def db_url
      case @options[:database]
      when "postgresql"
        "postgres://postgres:password@postgres:5432"
      when "mysql"
        "mysql2://root:password@mysql:3306"
      end
    end
  end
end

module AddAnnotate
  def add_annotate
    @generator.gem("annotate", group: :development)
    @generator.run("bundle install")
    @generator.rails_command("generate annotate:install")
    commit_all("add annotate")
  end
end

class BuildMyRails
  include MyCommand
  include AddMarginalia
  include Dockerdev
  include AddAnnotate

  attr_reader :generator, :app_name, :options
  def initialize(generator, app_name, options)
    @generator = generator
    @app_name = app_name
    @options = options
  end
end

bmr = BuildMyRails.new(self, app_name, @options)
bmr.initial_commit
bmr.readme
bmr.add_marginalia
bmr.dockerdev
bmr.add_annotate

after_bundle do
  git add: '.'
  git commit: '-m "after bundle"'
end

