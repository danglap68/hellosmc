web: bundle exec thrust ./bin/rails server
worker: bundle exec sidekiq -C config/sidekiq.yml
release: bin/rails db:migrate
