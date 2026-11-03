// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import * as ActiveStorage from "@rails/activestorage"

// Direct uploads (form.file_field ..., direct_upload: true) go straight to storage.
ActiveStorage.start()
