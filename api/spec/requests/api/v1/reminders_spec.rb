# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Reminders", type: :request do
  include ActiveJob::TestHelper
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:manager)    { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:other_consultant) { create(:user, :consultant, tenant: tenant) }
  let(:opportunity) { create(:opportunity, tenant: tenant, owner_user: consultant) }
  let(:other_opp)   { create(:opportunity, tenant: tenant, owner_user: other_consultant) }

  describe "GET /api/v1/reminders/stats" do
    let!(:pending_today) do
      create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity,
             status: "pending", remind_at: Time.zone.today.noon)
    end
    let!(:pending_overdue) do
      create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity,
             status: "pending", remind_at: 2.hours.ago)
    end
    let!(:done_reminder) do
      create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity, status: "done")
    end

    it "devuelve conteos pending, overdue, today y done" do
      get "/api/v1/reminders/stats", headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "pending")).to be >= 2
      expect(json.dig("data", "overdue")).to be >= 1
      expect(json.dig("data", "today")).to be >= 1
      expect(json.dig("data", "done")).to be >= 1
    end
  end

  describe "GET /api/v1/reminders" do
    let!(:mine) do
      create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity, subject: "Mio")
    end
    let!(:other) do
      create(:reminder, tenant: tenant, user: other_consultant, opportunity: other_opp, subject: "Ajeno")
    end

    it "manager ve todos los recordatorios del tenant (policy_scope)" do
      get "/api/v1/reminders", headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      subjects = json["data"].map { |d| d.dig("attributes", "subject") }
      expect(subjects).to include("Mio", "Ajeno")
      expect(json["included"]).to be_present if json["data"].any?
    end

    it "consultant solo ve los suyos o de sus oportunidades" do
      get "/api/v1/reminders", headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      subjects = json["data"].map { |d| d.dig("attributes", "subject") }
      expect(subjects).to include("Mio")
      expect(subjects).not_to include("Ajeno")
    end

    it "filtra por status y overdue" do
      mine.update!(remind_at: 2.hours.ago)

      get "/api/v1/reminders",
          params:  { status: "pending", overdue: "true" },
          headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(mine.id)
    end
  end

  describe "POST /api/v1/opportunities/:id/reminders" do
    it "crea recordatorio anidado (201)" do
      payload = {
        reminder: {
          remind_at: 2.days.from_now.iso8601,
          channel:   "in_app",
          subject:   "Llamar",
          message:   "Seguimiento"
        }
      }.to_json

      post "/api/v1/opportunities/#{opportunity.id}/reminders",
           params:  payload,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:created)
      expect(json.dig("data", "attributes", "subject")).to eq("Llamar")
      expect(ReminderCreatedNotificationJob).to have_been_enqueued
      expect(ReminderDueDispatchJob).to have_been_enqueued
    end

    it "sin user_id, el creador queda como responsable" do
      post "/api/v1/opportunities/#{opportunity.id}/reminders",
           params:  { reminder: { remind_at: 2.days.from_now.iso8601, channel: "in_app", subject: "Llamar" } }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:created)
      expect(Reminder.find(json.dig("data", "id")).user_id).to eq(consultant.id)
    end

    it "manager asigna el recordatorio a otro consultor via user_id" do
      post "/api/v1/opportunities/#{opportunity.id}/reminders",
           params:  {
             reminder: {
               remind_at: 2.days.from_now.iso8601, channel: "in_app", subject: "Llamar",
               user_id: other_consultant.id
             }
           }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:created)
      expect(Reminder.find(json.dig("data", "id")).user_id).to eq(other_consultant.id)
    end

    it "consultant no puede asignar user_id a otro — se ignora y queda como creador" do
      post "/api/v1/opportunities/#{opportunity.id}/reminders",
           params:  {
             reminder: {
               remind_at: 2.days.from_now.iso8601, channel: "in_app", subject: "Llamar",
               user_id: other_consultant.id
             }
           }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:created)
      expect(Reminder.find(json.dig("data", "id")).user_id).to eq(consultant.id)
    end
  end

  describe "POST /api/v1/reminders/:id/complete" do
    let!(:reminder) { create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity) }

    it "marca como done (204)" do
      post "/api/v1/reminders/#{reminder.id}/complete", headers: auth_headers(consultant)

      expect(response).to have_http_status(:no_content)
      expect(reminder.reload.status).to eq("done")
    end
  end

  describe "POST /api/v1/reminders/:id/snooze" do
    let!(:reminder) { create(:reminder, tenant: tenant, user: consultant, opportunity: opportunity) }

    it "pospone remind_at (204)" do
      post "/api/v1/reminders/#{reminder.id}/snooze",
           params:  { minutes: 30 }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:no_content)
      expect(reminder.reload.remind_at).to be > Time.current
    end
  end
end
