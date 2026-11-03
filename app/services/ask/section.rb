module Ask
  # A titled group of evidence items ("Current", "Expired", a project's gaps). total is
  # the full count when items was cut to AskQuery::LIST_LIMIT.
  Section = Data.define(:key, :title, :items, :total) do
    def initialize(key:, items:, title: nil, total: nil)
      super(key: key, title: title, items: items, total: total || items.size)
    end

    def truncated?
      total > items.size
    end
  end
end
