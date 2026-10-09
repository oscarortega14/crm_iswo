# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::WhatsappMessageNotifier do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:admin) { create(:user, :admin, tenant: tenant) }
  let(:manager) { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }

  def notify(contact:, opportunity: nil)
    msg = create(:whatsapp_message, tenant: tenant, contact: contact, opportunity: opportunity, direction: "in")
    described_class.call(message: msg)
    msg
  end

  it "no notifica mensajes salientes" do
    contact = create(:contact, tenant: tenant, owner_user: consultant)
    msg = create(:whatsapp_message, tenant: tenant, contact: contact, direction: "out")

    expect { described_class.call(message: msg) }.not_to change(Notification, :count)
  end

  it "notifica solo al dueño de la oportunidad cuando existe" do
    pipeline = create(:pipeline_with_stages, tenant: tenant)
    contact = create(:contact, tenant: tenant, owner_user: manager)
    opp = create(:opportunity, tenant: tenant, contact: contact, owner_user: consultant,
                 pipeline: pipeline, pipeline_stage: pipeline.pipeline_stages.first)

    expect { notify(contact: contact, opportunity: opp) }.to change(Notification, :count).by(1)

    n = Notification.last
    expect(n.user).to eq(consultant)
    expect(n.kind).to eq("whatsapp_message_received")
    expect(n.resource).to eq(contact)
  end

  it "notifica al dueño del contacto si no hay oportunidad" do
    contact = create(:contact, tenant: tenant, owner_user: consultant)

    expect { notify(contact: contact) }.to change(Notification, :count).by(1)
    expect(Notification.last.user).to eq(consultant)
  end

  it "notifica a admin y manager (no a todos los consultores) si el contacto no tiene dueño" do
    admin
    manager
    other_consultant = create(:user, :consultant, tenant: tenant)
    unowned = create(:contact, tenant: tenant)

    notify(contact: unowned)

    notified_users = Notification.where(kind: "whatsapp_message_received").pluck(:user_id)
    expect(notified_users).to contain_exactly(admin.id, manager.id)
    expect(notified_users).not_to include(other_consultant.id)
  end

  it "no duplica notificación si ya hay una sin leer para el mismo contacto (ráfaga de mensajes)" do
    contact = create(:contact, tenant: tenant, owner_user: consultant)

    notify(contact: contact)
    expect { notify(contact: contact) }.not_to change(Notification, :count)
  end

  it "sí notifica de nuevo si la anterior ya fue leída" do
    contact = create(:contact, tenant: tenant, owner_user: consultant)

    notify(contact: contact)
    Notification.last.mark_read!

    expect { notify(contact: contact) }.to change(Notification, :count).by(1)
  end

  it "un «Sí» se avisa como autorización, aunque haya otro aviso sin leer del mismo contacto" do
    contact = create(:contact, tenant: tenant, owner_user: consultant, first_name: "María", last_name: "Andrade")
    notify(contact: contact)

    msg = create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in", body: "Sí")
    expect { described_class.call(message: msg) }.to change(Notification, :count).by(1)
    expect(Notification.last).to have_attributes(title: "María Andrade autorizó WhatsApp",
                                                 body: /esperando respuesta/)
  end
end
