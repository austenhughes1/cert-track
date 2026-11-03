module CertificateTypesHelper
  # "Never expires", "1 month", "24 months".
  def certificate_type_validity(certificate_type)
    months = certificate_type.validity_months
    months ? pluralize(months, "month") : "Never expires"
  end
end
