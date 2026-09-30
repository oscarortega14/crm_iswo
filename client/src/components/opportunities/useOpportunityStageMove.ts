import { useCallback } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  invalidateContactSegmentMetrics,
  invalidateNotificationsQueries,
  queryKeys,
} from '@/lib/queryClient'
import { moveOpportunityStage } from '@/lib/opportunityApi'
import { useUser, useUserRole } from '@/stores/auth'
import type { Opportunity, Pipeline, PipelineStage } from '@/types'

/** Refleja la etapa nueva en la tarjeta antes de que responda la API. */
function patchOpportunityStage(
  opp: Opportunity,
  stageId: string,
  stages: PipelineStage[] | undefined,
): Opportunity {
  const stage = stages?.find((s) => s.id === stageId)
  let status = opp.status
  if (stage?.is_closed_won) status = 'won'
  else if (stage?.is_closed_lost) status = 'lost'

  return {
    ...opp,
    stage_id: stageId,
    status,
    stage: stage
      ? {
          id: stage.id,
          pipeline_id: stage.pipeline_id,
          name: stage.name,
          position: stage.position,
          probability: stage.probability,
          is_closed_won: stage.is_closed_won,
          is_closed_lost: stage.is_closed_lost,
          color: stage.color,
        }
      : opp.stage,
  }
}

/**
 * Mover una oportunidad de etapa desde el tablero (StageBoard).
 * Permisos: viewer nunca; red en solo lectura nunca; consultor solo propias.
 * Actualización optimista con rollback si la API falla.
 */
export function useOpportunityStageMove(pipeline?: Pipeline) {
  const queryClient = useQueryClient()
  const currentUser = useUser()
  const role = useUserRole()

  const canMove = useCallback(
    (opp: Opportunity) => {
      if (role === 'viewer') return false
      if (opp.network_read_only) return false
      if (role === 'admin' || role === 'manager') return true
      return String(opp.owner_id) === String(currentUser?.id ?? '')
    },
    [role, currentUser?.id],
  )

  const mutation = useMutation({
    mutationFn: async ({ id, stage_id }: { id: string; stage_id: string }) => {
      await moveOpportunityStage(id, stage_id)
    },
    onMutate: async ({ id, stage_id }) => {
      await queryClient.cancelQueries({ queryKey: queryKeys.opportunities.all })
      const snapshots = queryClient.getQueriesData<Opportunity[]>({
        queryKey: queryKeys.opportunities.all,
      })
      queryClient.setQueriesData<Opportunity[]>(
        {
          queryKey: queryKeys.opportunities.all,
          predicate: (q) => q.queryKey[1] === 'list',
        },
        (old) =>
          old?.map((o) =>
            o.id === id ? patchOpportunityStage(o, stage_id, pipeline?.stages) : o,
          ),
      )
      return { snapshots }
    },
    onSuccess: (_data, { stage_id }) => {
      const stageName =
        pipeline?.stages?.find((s) => s.id === stage_id)?.name ?? 'nueva etapa'
      toast.success(`Movida a ${stageName}`)
      queryClient.invalidateQueries({ queryKey: ['dashboard'] })
      void invalidateContactSegmentMetrics(queryClient)
      void invalidateNotificationsQueries(queryClient)
    },
    onError: (_err, _vars, context) => {
      context?.snapshots.forEach(([key, data]) => {
        queryClient.setQueryData(key, data)
      })
      toast.error('Error al mover la oportunidad')
      queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all })
    },
  })

  const moveStage = useCallback(
    (opp: Opportunity, stageId: string) => {
      if (!canMove(opp) || stageId === opp.stage_id) return
      mutation.mutate({ id: opp.id, stage_id: stageId })
    },
    [canMove, mutation],
  )

  return { canMove, moveStage, isPending: mutation.isPending }
}
