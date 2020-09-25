git :init
git add: '.'
git commit: '-m "rails new"'

# Change README
puts
say_status "README", "Changing README...\n", :yellow
puts '-'*80, ''; sleep 0.2

remove_file 'README.md'

create_file 'README.md', <<~README
# Dockerdev
Imitating Martian technology.
[Terraforming Rails](https://github.com/evilmartians/terraforming-rails)
[dockerdev](https://github.com/evilmartians/terraforming-rails/tree/master/examples/dockerdev)

## Provision
```sh
dip provision
```
README

git add: 'README.md'
git commit: '-m "README"'

# use postgres
comment_lines 'Gemfile', /gem 'sqlite3/

gem 'pg', '>= 0.18', '< 2.0'

gsub_file 'config/database.yml', %r{^default:.*?\n{2}}m, <<-YML
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  url: <%= ENV['DATABASE_URL'] %>

YML
gsub_file 'config/database.yml', %r{^development:.*?\n{2}}m, <<-YML
development:
  <<: *default
  database: #{app_name}_development

YML
gsub_file 'config/database.yml', %r{^test:.*?\n{2}}m, <<-YML
test:
  <<: *default
  database: #{app_name}_test

YML
gsub_file 'config/database.yml', %r{^production:.*?\z}m, <<-YML
production:
  <<: *default
  database: #{app_name}_production
  username: #{app_name}
  password: <%= ENV['#{app_name.upcase}_DATABASE_PASSWORD'] %>
YML

git add: '.'
git commit: '-m "pg"'

# Add docker-compose

create_file 'docker-compose.yml', <<~DC
version: '3.4'

x-app: &app
  build:
    context: .
    dockerfile: ./.dockerdev/app/Dockerfile
    args:
      RUBY_VERSION: '2.7.1'
      PG_MAJOR: '12'
      NODE_MAJOR: '12'
      YARN_VERSION: '1.22.5'
      BUNDLER_VERSION: '2.1.4'
  environment: &env
    NODE_ENV: development
    RAILS_ENV: ${RAILS_ENV:-development}
  image: es_sample
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
    DATABASE_URL: postgres://postgres:password@postgres:5432
    BOOTSNAP_CACHE_DIR: /usr/local/bundle/_bootsnap
    WEBPACKER_DEV_SERVER_HOST: webpacker
    HISTFILE: /app/log/.bash_history
    PSQL_HISTFILE: /app/log/.psql_history
    EDITOR: vi
  depends_on:
    - postgres

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

  postgres:
    image: postgres:12
    volumes:
      - postgres:/var/lib/postgresql/data
      - ./log:/root/log:cached
    environment:
      PSQL_HISTFILE: /root/log/.psql_history
      POSTGRES_PASSWORD: password
    ports:
      - 5432
    healthcheck:
      test: pg_isready -U postgres -h 127.0.0.1
      interval: 5s

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
volumes:
  bundle:
  node_modules:
  packs:
  postgres:
  rails_cache:
  redis:
DC

create_file '.docker/app/Dockerfile', <<~DOCKER
ARG RUBY_VERSION
FROM ruby:$RUBY_VERSION-slim-buster

ARG PG_MAJOR
ARG NODE_MAJOR
ARG BUNDLER_VERSION
ARG YARN_VERSION

# Common dependencies
RUN apt-get update -qq \
  && DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    build-essential \
    gnupg2 \
    curl \
    less \
    git \
  && apt-get clean \
  && rm -rf /var/cache/apt/archives/* \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
  && truncate -s 0 /var/log/*log

# Add PostgreSQL to sources list
RUN curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && echo 'deb http://apt.postgresql.org/pub/repos/apt/ buster-pgdg main' $PG_MAJOR > /etc/apt/sources.list.d/pgdg.list

# Add NodeJS to sources list
RUN curl -sL https://deb.nodesource.com/setup_$NODE_MAJOR.x | bash -

# Add Yarn to the sources list
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
  && echo 'deb http://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list

# Install dependencies
COPY .dockerdev/app/Aptfile /tmp/Aptfile
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    libpq-dev \
    postgresql-client-$PG_MAJOR \
    nodejs \
    yarn=$YARN_VERSION-1 \
    $(cat /tmp/Aptfile | xargs) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    truncate -s 0 /var/log/*log

# Configure bundler
ENV LANG=C.UTF-8 \
  BUNDLE_JOBS=4 \
  BUNDLE_RETRY=3
RUN gem update --system && \
    rm /usr/local/lib/ruby/gems/*/specifications/default/bundler-*.gemspec && \
    gem uninstall bundler && \
    gem install bundler -v $BUNDLER_VERSION

RUN mkdir -p /app

WORKDIR /app
DOCKER

create_file '.dockerdev/app/Aptfile', <<~APT
vim
APT

create_file 'dip.yml', <<~DIP
version: '4.1'

environment:
  RAILS_ENV: development

compose:
  files:
    - docker-compose.yml
  # specify project name explicitly to avoid name collisions:
  # docker-compose use the compose file's folder name as the project name by default,
  # which could be the same for different projects (e.g., if you store docker-compose.yml
  # in the .dockerdev/ folder)
  # project_name: my_project_dev

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
        description: Run Rails server available at http://localhost:3030
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

  psql:
    description: Run psql console
    service: postgres
    command: psql -h postgres -U postgres -d #{app_name}_development

  'redis-cli':
    description: Run Redis console
    service: redis
    command: redis-cli -h redis

provision:
  - dip compose down --volumes
  - dip compose up -d postgres redis
  - dip bundle install
  - dip yarn install
  - dip rails db:setup
DIP

git add: '.'
git commit: '-m "dockerdev"'

after_bundle do
  git add: '.'
  git commit: '-m "after bundle"'
end
