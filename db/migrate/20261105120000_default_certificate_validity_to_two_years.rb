# Owner's rule, Nov 5, 2026: a certificate that states no expiry or validity lasts 2 years, except
# OSHA 10 and 30, which never expire. A blank validity means "never expires", and every seeded type
# was still blank, so this gives them 24 months. Certificates whose dates came from the type follow
# (Certificate#rederive_expiry! in plain SQL, so the migration doesn't depend on the models).
class DefaultCertificateValidityToTwoYears < ActiveRecord::Migration[8.1]
  COMPUTED = 1
  NONE = 3

  def up
    execute <<~SQL.squish
      UPDATE certificate_types SET validity_months = 24, updated_at = now()
      WHERE validity_months IS NULL AND code NOT IN ('OSHA10', 'OSHA30')
    SQL
    execute <<~SQL.squish
      UPDATE certificate_types SET validity_months = NULL, updated_at = now()
      WHERE validity_months IS NOT NULL AND code IN ('OSHA10', 'OSHA30')
    SQL
    execute <<~SQL.squish
      UPDATE certificates SET expires_on = certificates.completed_on + make_interval(months => t.validity_months),
        expires_on_source = #{COMPUTED}, updated_at = now()
      FROM certificate_types t
      WHERE t.id = certificates.certificate_type_id AND t.validity_months IS NOT NULL
        AND certificates.expires_on_source IN (#{COMPUTED}, #{NONE})
    SQL
    execute <<~SQL.squish
      UPDATE certificates SET expires_on = NULL, expires_on_source = #{NONE}, updated_at = now()
      FROM certificate_types t
      WHERE t.id = certificates.certificate_type_id AND t.validity_months IS NULL
        AND certificates.expires_on_source = #{COMPUTED}
    SQL
  end

  def down
    # Which types were blank before can't be told apart from the owner's edits; nothing to undo.
  end
end
