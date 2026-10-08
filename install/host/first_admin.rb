# frozen_string_literal: true

# The first administrator, from ADMIN_EMAIL / ADMIN_PASSWORD. On a new
# database the host's db/seeds.rb creates admin@example.com with a published
# password, and FairData's invitation hook at once replaces it with a random
# one and queues an email with it. That account is taken over (or, if it's
# gone, a new one made), so no install keeps the published password or one
# nobody knows. Runs on every start; once the administrator has signed in,
# nothing changes.
email = ENV['ADMIN_EMAIL'].to_s.strip.downcase
password = ENV['ADMIN_PASSWORD'].to_s
PUBLISHED = 'Changeme1!!'

abort '[install] Set ADMIN_EMAIL and ADMIN_PASSWORD in .env.' if email.empty? || password.empty?
abort '[install] ADMIN_PASSWORD is the published default; choose another.' if password == PUBLISHED

User = CoreDataConnector::User
user = User.find_by(email:)
# The seed's account, until someone signs in with it (ADMIN_EMAIL may be its
# own address).
seeded = User.find_by(email: 'admin@example.com', last_sign_in_at: nil)

if user.nil? || user == seeded
  user = seeded || User.new(name: 'Administrator')
  user.skip_invitation = true
  user.assign_attributes(email:, password:, password_confirmation: password, role: User::ROLE_ADMIN)
  user.require_password_change = false if user.respond_to?(:require_password_change=)
  user.save!
  puts "[install] administrator #{email}: #{seeded ? 'took over the seeded account' : 'created'}"

  if seeded
    # The invitation queued for the seeded account: the worker hasn't started
    # yet. Drop it; it would now go to ADMIN_EMAIL with a password that no
    # longer works.
    require 'sidekiq/api'
    gid = "\"#{seeded.to_global_id}\""
    Sidekiq::Queue.all.each do |queue|
      queue.each do |job|
        job.delete if job.display_class == 'CoreDataConnector::InvitationMailer#invite_user' && job.value.include?(gid)
      end
    end
  end
# authenticate_password, not authenticate: FairData's #authenticate also
# records a sign-in.
elsif user.authenticate_password(PUBLISHED)
  user.update!(password:, password_confirmation: password, role: User::ROLE_ADMIN)
  puts "[install] administrator #{email}: password set from ADMIN_PASSWORD"
else
  puts "[install] administrator #{email} exists"
end
