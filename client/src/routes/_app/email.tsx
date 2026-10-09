import { createFileRoute } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { z } from 'zod'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { EmailCampaignsPanel } from '@/components/email/EmailCampaignsPanel'
import { EmailSenderPanel } from '@/components/email/EmailSenderPanel'
import { requireRole } from '@/lib/authGuards'
import { emailQueryKeys, fetchEmailSender } from '@/lib/emailMarketingApi'
import { useUserRole } from '@/stores/auth'

const emailSearchSchema = z.object({
  tab: z.enum(['campaigns', 'sender']).optional(),
})

// Mismo alcance que el backend (EmailCampaignPolicy): admin y manager.
export const Route = createFileRoute('/_app/email')({
  validateSearch: emailSearchSchema,
  beforeLoad: () => requireRole('admin', 'manager'),
  component: EmailMarketingPage,
})

function EmailMarketingPage() {
  const role = useUserRole()
  const { tab } = Route.useSearch()
  const navigate = Route.useNavigate()

  const { data: sender, isLoading } = useQuery({
    queryKey: emailQueryKeys.sender(),
    queryFn: fetchEmailSender,
  })

  const verified = sender?.status === 'verified'
  const current = tab ?? (sender && !sender.domain && role === 'admin' ? 'sender' : 'campaigns')

  return (
    <AppPageShell>
      <PageHeader
        title="Email marketing"
        description="Campañas de correo desde el dominio de tu empresa, con baja en un clic y resultados por contacto."
      />

      {isLoading || !sender ? (
        <Skeleton className="h-64 w-full rounded-lg" />
      ) : (
        <Tabs
          value={current}
          onValueChange={(v) => void navigate({ search: { tab: v as 'campaigns' | 'sender' }, replace: true })}
        >
          <TabsList>
            <TabsTrigger value="campaigns">Campañas</TabsTrigger>
            <TabsTrigger value="sender">
              Remitente
              {!verified && <span className="ml-1.5 size-2 rounded-full bg-amber-500" aria-label="Sin verificar" />}
            </TabsTrigger>
          </TabsList>
          <TabsContent value="campaigns" className="mt-4">
            <EmailCampaignsPanel senderVerified={verified} />
          </TabsContent>
          <TabsContent value="sender" className="mt-4">
            <EmailSenderPanel sender={sender} canEdit={role === 'admin'} />
          </TabsContent>
        </Tabs>
      )}
    </AppPageShell>
  )
}
