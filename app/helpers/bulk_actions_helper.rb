module BulkActionsHelper
  def bulk_table_attributes(resource = nil)
    config = BulkActions::Catalog::RESOURCES[resource.to_s]
    operations = config && can?(:manage, config[1]) ? config[2] : []
    tag.attributes(data: {
      controller: "bulk-table", bulk_table_resource_value: resource,
      bulk_table_operations_value: operations.map { |key| { key: key, label: t("bulk.operations.#{key}") } },
      bulk_table_labels_value: t("bulk.labels"), bulk_table_url_value: admin_bulk_actions_path
    })
  end

  def bulk_row_attributes(record)
    attributes = { bulk_id: record.id, bulk_version: BulkActions::Catalog.version(record) }
    attributes[:bulk_reason] = suggested_rejection_reason(record) if record.is_a?(Transaction)
    if record.is_a?(RemitterTransfer)
      attributes[:bulk_reason] = record.review_reasons.map { |reason| remitter_transfer_reason(reason) }.join("; ")
    end
    tag.attributes(data: attributes)
  end
end
