namespace :certtrack do
  desc "Create or promote an admin. EMAIL=… [NAME=…] [PASSWORD=…]; prompts on a terminal, else generates a password"
  task create_admin: :environment do
    require "io/console"

    email = ENV["EMAIL"].presence
    if email.nil? && $stdin.tty?
      $stderr.print "Email: "
      email = $stdin.gets.to_s.strip.presence
    end
    abort "EMAIL is required, e.g. bin/rails certtrack:create_admin EMAIL=you@example.com NAME='Your Name'" if email.blank?

    existing = User.find_by(email_address: email)
    password = ENV["PASSWORD"].presence
    generated = false

    # Existing users keep their password unless PASSWORD is given.
    if password.nil? && existing.nil?
      if $stdin.tty?
        password = $stdin.getpass("Password (8+ characters): ")
        abort "Passwords did not match." unless password == $stdin.getpass("Repeat password: ")
      else
        password = User.generate_password
        generated = true
      end
    end

    begin
      user = User.create_or_promote_admin!(email_address: email, name: ENV["NAME"], password: password)
    rescue ActiveRecord::RecordInvalid => e
      abort "Could not save admin: #{e.record.errors.full_messages.to_sentence}"
    end

    status = if existing.nil? then "Created admin"
    elsif existing.admin? then "Updated admin"
    else "Promoted #{existing.role} to admin"
    end
    puts "#{status} #{user.email_address}."
    puts "Password changed." if existing && password
    puts "Generated password (shown once, store it now): #{password}" if generated
  end
end
