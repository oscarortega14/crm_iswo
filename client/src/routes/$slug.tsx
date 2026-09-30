import { createFileRoute, redirect } from '@tanstack/react-router'
import { PublicLandingPage } from '@/components/landings/PublicLandingPage'
import { getTenantFromHostname } from '@/lib/landingUrls'
import { landingUtmSearchSchema } from '@/lib/landingSearch'

export const Route = createFileRoute('/$slug')({
  validateSearch: landingUtmSearchSchema,
  beforeLoad: ({ params, search }) => {
    if (!getTenantFromHostname()) {
      throw redirect({
        to: '/l/$slug',
        params: { slug: params.slug },
        search,
      })
    }
  },
  component: SubdomainLandingRoute,
})

/** RFC: https://{tenant}.iswocrm.com/{slug} — en dev: {tenant}.localhost:3001/{slug} */
function SubdomainLandingRoute() {
  const { slug } = Route.useParams()
  return <PublicLandingPage slug={slug} />
}
