# The certificates the crew actually hold that the example list didn't have (owner, Nov 5, 2026).
# Any certificate can be a type, and projects choose which to require. Plain SQL so the migration
# doesn't depend on the models; an existing name or code is left as edited.
class AddCertificateTypesFromRealCertificates < ActiveRecord::Migration[8.1]
  TYPES = [
    [ "BBP", "Bloodborne Pathogens", [ "BBP", "Bloodborne Pathogens Training" ] ],
    [ "HAZCOM", "Hazard Communication", [ "HazCom", "Hazard Communication Training", "GHS" ] ],
    [ "TRENCHING", "Trenching and Excavation Safety", [ "Excavation Safety", "Trenching Safety" ] ],
    [ "GCACADEMY", "GC Academy Construction", [ "T-Mobile GC Academy" ] ],
    [ "CAPSTAN", "Capstan Hoist Operations", [ "Capstan Hoist" ] ],
    [ "NWSATTT", "NWSA Telecommunications Tower Technician", [ "NWSA Tower Technician", "TTT-1" ] ]
  ].freeze

  def up
    now = connection.quote(Time.current)
    TYPES.each do |code, name, aliases|
      values = [ name, code, PG::TextEncoder::Array.new.encode(aliases), 24, true ].map { |value| connection.quote(value) }
      execute <<~SQL.squish
        INSERT INTO certificate_types (name, code, aliases, validity_months, active, position, created_at, updated_at)
        VALUES (#{values.join(", ")}, (SELECT coalesce(max(position), 0) + 1 FROM certificate_types), #{now}, #{now})
        ON CONFLICT DO NOTHING
      SQL
    end
  end

  def down
    # Certificates may already use these types.
  end
end
