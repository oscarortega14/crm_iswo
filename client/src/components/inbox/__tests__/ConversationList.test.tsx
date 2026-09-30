import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ConversationList } from '../ConversationList'
import type { ConversationRow } from '@/lib/whatsappInboxApi'

function row(overrides: Partial<ConversationRow>): ConversationRow {
  return {
    contactId: '1',
    contactName: 'Contacto',
    contactPhone: '+573000000000',
    opportunityId: null,
    opportunityStage: null,
    ownerUserId: null,
    ownerName: null,
    lastMessageBody: 'hola',
    lastMessageDirection: 'in',
    lastMessageStatus: 'received',
    lastMessageAt: null,
    unreadCount: 0,
    bucket: 'mine',
    awaitingReply: false,
    automationPaused: false,
    ...overrides,
  }
}

const conversations = [
  row({ contactId: '1', contactName: 'Ana Leída', unreadCount: 0 }),
  row({ contactId: '2', contactName: 'Beto Pendiente', unreadCount: 3 }),
  row({ contactId: '3', contactName: 'Carla Abierta', unreadCount: 0 }),
  row({ contactId: '4', contactName: 'Diana Autorizó', unreadCount: 0, awaitingReply: true }),
]

function renderList(activeContactId: string | null = null) {
  return render(
    <ConversationList
      conversations={conversations}
      isLoading={false}
      activeContactId={activeContactId}
      onSelect={vi.fn()}
      scope="all"
      onScopeChange={vi.fn()}
      canSeeAll
      search=""
      onSearchChange={vi.fn()}
    />,
  )
}

describe('ConversationList — no leídas', () => {
  it('marca las conversaciones con mensajes sin leer para lectores de pantalla', () => {
    renderList()
    expect(screen.getByRole('button', { name: 'Beto Pendiente, 3 mensaje(s) sin leer' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Ana Leída' })).toBeInTheDocument()
  })

  it('el filtro "No leídas" oculta las leídas pero mantiene visible la conversación abierta', async () => {
    renderList('3')
    await userEvent.click(screen.getByRole('button', { name: /No leídas/ }))

    expect(screen.getByText('Beto Pendiente')).toBeInTheDocument()
    expect(screen.getByText('Carla Abierta')).toBeInTheDocument()
    expect(screen.queryByText('Ana Leída')).not.toBeInTheDocument()
  })
})

describe('ConversationList — autorizaron', () => {
  it('muestra solo a quienes dijeron «Sí» y esperan respuesta, con su conteo', async () => {
    renderList()
    await userEvent.click(screen.getByRole('button', { name: /Autorizaron/ }))

    expect(screen.getByText('Diana Autorizó')).toBeInTheDocument()
    expect(screen.queryByText('Beto Pendiente')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Autorizaron/ })).toHaveTextContent('1')
  })
})
