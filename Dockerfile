# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION} AS base

ENV BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production \
    NODE_ENV=production

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev git curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs=4 --retry=3

COPY . .

RUN SECRET_KEY_BASE=dummy bundle exec rails assets:precompile

FROM ruby:${RUBY_VERSION}-slim AS final

ENV BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1 \
    NODE_ENV=production

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends libpq5 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=base /usr/local/bundle /usr/local/bundle
COPY --from=base /app /app

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
