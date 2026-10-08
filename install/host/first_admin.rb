# frozen_string_literal: true

# The first administrator, from ADMIN_EMAIL / ADMIN_PASSWORD. The host's
# db/seeds.rb creates admin@example.com with a published password on a new
# database; that account is taken over (or, if it's gone, a new one made), so
# no install runs with a known password. Run on every start: once the
# administrator exists with a password of its own, nothing changes.
email = ENV['ADMIN_EMAIL'].to_s.strip.downcase
password = ENV['ADMIN_PASSWORD'].to_s
PUBLISHED = 'Changeme1!!'

abort '[install] Set ADMIN_EMAIL and ADMIN_PASSWORD in .env.' if email.empty? || password.empty?
abort '[install] ADMIN_PASSWORD is the published default; choose another.' if password == PUBLISHED

User = CoreDataConnector::User
user = User.find_by(email:)

if user.nil?
  seeded = User.find_by(email: 'admin@example.com')
  user = seeded || User.new(name: 'Administrator')
  user.skip_invitation = true
  user.assign_attributes(email:, password:, password_confirmation: password, role: User::ROLE_ADMIN)
  user.require_password_change = false if user.respond_to?(:require_password_change=)
  user.save!
  puts "[install] administrator #{email}: #{seeded ? 'took over the seeded admin@example.com' : 'created'}"

  if seeded
    # FairData invited the seeded account as it was made, with a new password
    # in the email. The worker hasn't started yet; drop that email, which
    # would now go to ADMIN_EMAIL with a password that no longer works.
    require 'sidekiq/api'
    gid = "\"#{seeded.to_global_id}\""
    Sidekiq::Queue.all.each do |queue|
      queue.each do |job|
        job.delete if job.display_class == 'CoreDataConnector::InvitationMailer#invite_user' && job.value.include?(gid)
      end
    end
  end
elsif user.authenticate(PUBLISHED)
  user.update!(password:, password_confirmation: password, role: User::ROLE_ADMIN)
  puts "[install] administrator #{email}: password set from ADMIN_PASSWORD"
else
  puts "[install] administrator #{email} exists"
end

# No other account may keep the published seed password.
User.where.not(id: user.id).find_each do |other|
  next unless other.authenticate(PUBLISHED)

  other.update!(password: "#{SecureRandom.base58(32)}Aa1!")
  puts "[install] #{other.email} no longer has the published password"
end
