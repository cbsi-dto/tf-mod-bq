/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  tables             = { for table in var.tables : table["table_id"] => table }
  views              = { for view in var.views : view["view_id"] => view }
  materialized_views = { for mat_view in var.materialized_views : mat_view["view_id"] => mat_view }
  external_tables    = { for external_table in var.external_tables : external_table["table_id"] => external_table }
  routines           = { for routine in var.routines : routine["routine_id"] => routine }

  auth_role_keys = [
    for role in var.access :
    join("_", compact([
      role["role"],
      lookup(role, "domain", null),
      lookup(role, "group_by_email", null),
      lookup(role, "user_by_email", null),
      lookup(role, "special_group", null)
    ]))
  ]
  auth_roles    = zipmap(local.auth_role_keys, var.access)
  auth_views    = { for view in var.authorized_views : "${view["project_id"]}_${view["dataset_id"]}_${view["table_id"]}" => view }
  auth_datasets = { for dataset in var.authorized_datasets : "${dataset["project_id"]}_${dataset["dataset_id"]}" => dataset }

  iam_to_primitive = {
    "roles/bigquery.dataOwner" : "OWNER"
    "roles/bigquery.dataEditor" : "WRITER"
    "roles/bigquery.dataViewer" : "READER"
  }
}

resource "google_bigquery_dataset" "main" {
  dataset_id                  = var.dataset_id
  friendly_name               = var.dataset_name
  description                 = var.description
  location                    = var.location
  delete_contents_on_destroy  = var.delete_contents_on_destroy
  default_table_expiration_ms = var.default_table_expiration_ms
  max_time_travel_hours       = var.max_time_travel_hours
  project                     = var.project_id
  labels                      = var.dataset_labels
  is_case_insensitive         = var.is_case_insensitive

  dynamic "default_encryption_configuration" {
    for_each = var.encryption_key == null ? [] : [var.encryption_key]
    content {
      kms_key_name = var.encryption_key
    }
  }

  dynamic "access" {
    for_each = local.auth_roles
    content {
      # BigQuery API converts IAM to primitive roles in its backend.
      # This causes Terraform to show a diff on every plan that uses IAM equivalent roles.
      # Thus, do the conversion between IAM to primitive role here to prevent the diff.
      role = lookup(local.iam_to_primitive, access.value.role, access.value.role)

      # Additionally, using null as a default value would lead to a permanant diff
      # See https://github.com/hashicorp/terraform-provider-google/issues/4085#issuecomment-516923872
      domain         = lookup(access.value, "domain", "")
      group_by_email = lookup(access.value, "group_by_email", "")
      user_by_email  = lookup(access.value, "user_by_email", "")
      special_group  = lookup(access.value, "special_group", "")
    }
  }

  dynamic "access" {
    for_each = local.auth_views
    content {
      role           = ""
      group_by_email = ""
      user_by_email  = ""
      special_group  = ""
      domain         = ""
      view {
        project_id = access.value.project_id
        dataset_id = access.value.dataset_id
        table_id   = access.value.table_id
      }
    }
  }

  dynamic "access" {
    for_each = local.auth_datasets
    content {
      role           = ""
      group_by_email = ""
      user_by_email  = ""
      special_group  = ""
      domain         = ""
      dataset {
        dataset {
          project_id = access.value.project_id
          dataset_id = access.value.dataset_id
        }
        target_types = ["VIEWS"]
      }
    }
  }

  dynamic "access" {
    for_each = local.auth_views
    content {
      role           = ""
      group_by_email = ""
      user_by_email  = ""
      special_group  = ""
      domain         = ""
      view {
        project_id = access.value.project_id
        dataset_id = access.value.dataset_id
        table_id   = access.value.table_id
      }
    }
  }

  dynamic "access" {
    for_each = local.auth_datasets
    content {
      role           = ""
      group_by_email = ""
      user_by_email  = ""
      special_group  = ""
      domain         = ""
      dataset {
        dataset {
          project_id = access.value.project_id
          dataset_id = access.value.dataset_id
        }
        target_types = ["VIEWS"]
      }
    }
  }
}

resource "google_bigquery_table" "main" {
  for_each            = local.tables
  dataset_id          = google_bigquery_dataset.main.dataset_id
  friendly_name       = each.value["table_name"] != null ? each.value["table_name"] : each.key
  table_id            = each.key
  description         = each.value["description"]
  labels              = each.value["labels"]
  schema              = each.value["schema"]
  clustering          = each.value["clustering"]
  expiration_time     = each.value["expiration_time"]
  max_staleness       = each.value["max_staleness"]
  project             = var.project_id
  deletion_protection = each.value["deletion_protection"]

  dynamic "time_partitioning" {
    for_each = each.value["time_partitioning"] != null ? [each.value["time_partitioning"]] : []
    content {
      type                     = time_partitioning.value["type"]
      expiration_ms            = time_partitioning.value["expiration_ms"] != null ? time_partitioning.value["expiration_ms"] : 0
      field                    = time_partitioning.value["field"]
      require_partition_filter = time_partitioning.value["require_partition_filter"]
    }
  }

  dynamic "range_partitioning" {
    for_each = each.value["range_partitioning"] != null ? [each.value["range_partitioning"]] : []
    content {
      field = range_partitioning.value["field"]
      range {
        start    = range_partitioning.value["range"].start
        end      = range_partitioning.value["range"].end
        interval = range_partitioning.value["range"].interval
      }
    }
  }

  lifecycle {
    ignore_changes = [
      encryption_configuration # managed by google_bigquery_dataset.main.default_encryption_configuration
    ]
  }
}

resource "google_bigquery_table" "view" {
  for_each            = local.views
  dataset_id          = google_bigquery_dataset.main.dataset_id
  friendly_name       = each.key
  description         = each.value["description"]
  schema              = each.value["schema"]
  table_id            = each.key
  labels              = each.value["labels"]
  project             = var.project_id
  deletion_protection = false

  view {
    query          = each.value["query"]
    use_legacy_sql = each.value["use_legacy_sql"]
  }

  lifecycle {
    ignore_changes = [
      encryption_configuration # managed by google_bigquery_dataset.main.default_encryption_configuration
    ]
  }
}

resource "google_bigquery_table" "materialized_view" {
  for_each            = local.materialized_views
  dataset_id          = google_bigquery_dataset.main.dataset_id
  friendly_name       = each.key
  table_id            = each.key
  description         = each.value["description"]
  labels              = each.value["labels"]
  clustering          = each.value["clustering"]
  expiration_time     = each.value["expiration_time"] != null ? each.value["expiration_time"] : 0
  max_staleness       = each.value["max_staleness"]
  project             = var.project_id
  deletion_protection = false

  dynamic "time_partitioning" {
    for_each = each.value["time_partitioning"] != null ? [each.value["time_partitioning"]] : []
    content {
      type                     = time_partitioning.value["type"]
      expiration_ms            = time_partitioning.value["expiration_ms"] != null ? time_partitioning.value["expiration_ms"] : 0
      field                    = time_partitioning.value["field"]
      require_partition_filter = time_partitioning.value["require_partition_filter"]
    }
  }

  dynamic "range_partitioning" {
    for_each = each.value["range_partitioning"] != null ? [each.value["range_partitioning"]] : []
    content {
      field = range_partitioning.value["field"]
      range {
        start    = range_partitioning.value["range"].start
        end      = range_partitioning.value["range"].end
        interval = range_partitioning.value["range"].interval
      }
    }
  }

  materialized_view {
    query               = each.value["query"]
    enable_refresh      = each.value["enable_refresh"]
    refresh_interval_ms = each.value["refresh_interval_ms"]
  }

  lifecycle {
    ignore_changes = [
      encryption_configuration # managed by google_bigquery_dataset.main.default_encryption_configuration
    ]
  }
}

resource "google_bigquery_table" "external_table" {
  for_each            = local.external_tables
  dataset_id          = google_bigquery_dataset.main.dataset_id
  friendly_name       = each.key
  table_id            = each.key
  description         = each.value["description"]
  labels              = each.value["labels"]
  expiration_time     = each.value["expiration_time"]
  max_staleness       = each.value["max_staleness"]
  project             = var.project_id
  deletion_protection = false
  schema              = each.value["connection_id"] != null && !each.value["autodetect"] ? each.value["schema"] : null

  external_data_configuration {
    autodetect            = each.value["autodetect"]
    compression           = each.value["compression"]
    ignore_unknown_values = each.value["ignore_unknown_values"]
    max_bad_records       = each.value["max_bad_records"]
    schema                = each.value["connection_id"] == null && !each.value["autodetect"] ? each.value["schema"] : null
    source_format         = each.value["source_format"]
    source_uris           = each.value["source_uris"]
    metadata_cache_mode   = each.value["metadata_cache_mode"]
    connection_id         = each.value["connection_id"]

    dynamic "csv_options" {
      for_each = each.value["csv_options"] != null ? [each.value["csv_options"]] : []
      content {
        quote                 = csv_options.value["quote"]
        allow_jagged_rows     = csv_options.value["allow_jagged_rows"]
        allow_quoted_newlines = csv_options.value["allow_quoted_newlines"]
        encoding              = csv_options.value["encoding"]
        field_delimiter       = csv_options.value["field_delimiter"]
        skip_leading_rows     = csv_options.value["skip_leading_rows"]
      }
    }

    dynamic "google_sheets_options" {
      for_each = each.value["google_sheets_options"] != null ? [each.value["google_sheets_options"]] : []
      content {
        range             = google_sheets_options.value["range"]
        skip_leading_rows = google_sheets_options.value["skip_leading_rows"]
      }
    }

    dynamic "hive_partitioning_options" {
      for_each = each.value["hive_partitioning_options"] != null ? [each.value["hive_partitioning_options"]] : []
      content {
        mode              = hive_partitioning_options.value["mode"]
        source_uri_prefix = hive_partitioning_options.value["source_uri_prefix"]
      }
    }

    dynamic "parquet_options" {
      for_each = each.value["parquet_options"] != null ? [each.value["parquet_options"]] : []
      content {
        enum_as_string        = parquet_options.value["enum_as_string"]
        enable_list_inference = parquet_options.value["enable_list_inference"]
      }
    }

    dynamic "avro_options" {
      for_each = each.value["avro_options"] != null ? [each.value["avro_options"]] : []
      content {
        use_avro_logical_types = avro_options.value["use_avro_logical_types "]
      }
    }
  }

  lifecycle {
    ignore_changes = [
      encryption_configuration # managed by google_bigquery_dataset.main.default_encryption_configuration
    ]
  }
}

resource "google_bigquery_routine" "routine" {
  for_each        = local.routines
  dataset_id      = google_bigquery_dataset.main.dataset_id
  routine_id      = each.key
  description     = each.value["description"]
  routine_type    = each.value["routine_type"]
  language        = each.value["language"]
  definition_body = each.value["definition_body"]
  project         = var.project_id

  dynamic "arguments" {
    for_each = each.value["arguments"] != null ? each.value["arguments"] : []
    content {
      name          = arguments.value["name"]
      data_type     = arguments.value["data_type"]
      mode          = arguments.value["mode"]
      argument_kind = arguments.value["argument_kind"]
    }
  }

  return_type = each.value["return_type"]
}
