# frozen_string_literal: true

# Google Calendar simulado para los specs de la agenda del asistente IA.
class FakeGoogleCalendar
  attr_reader :created, :moved, :deleted
  attr_accessor :busy_ranges

  def initialize(busy_ranges = [])
    @busy_ranges = busy_ranges
    @created = []
    @moved = []
    @deleted = []
  end

  def busy(from, to)
    @busy_ranges.select { |(s, e)| s < to && e > from }
  end

  def create_event(**attrs)
    @created << attrs
    "evt_#{@created.size}"
  end

  def move_event(event_id, **attrs)
    @moved << attrs.merge(event_id: event_id)
  end

  def delete_event(event_id)
    @deleted << event_id
  end
end
