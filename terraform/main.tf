# BigQuery Dataset
# Confluent Environment
# Confluent Kafka Cluster
# Confluent Kafka Topic
# Confluent Schema Registry Cluster
# Confluent ksqlDB
# Confluent Kafka BigQuery Connector

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.24.0"
    }
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.70.0"
    }
  }
}

provider "google" {
  credentials = file(var.gcp_credentials)
  project     = var.gcp_project
  region      = var.gcp_region
  zone        = var.gcp_zone
}

# Option #1: Manage multiple clusters in the same Terraform workspace
# See https://registry.terraform.io/providers/confluentinc/confluent/latest/docs for more details
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}


# Define GCP resources
# Create a BigQuery Dataset
resource "google_bigquery_dataset" "dezoom_coinbase_stream_terraform" {
  dataset_id                 = var.gcp_dataset
  location                   = var.gcp_location
  delete_contents_on_destroy = true
}


# Define Confluent Cloud resources
# Confluent Environment
resource "confluent_environment" "dezoom_project_env" {
  display_name = "dezoom_project_env"

  # stream_governance {
  #   package = "ESSENTIALS"
  # }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Confluent Schema Registry Cluster
data "confluent_schema_registry_region" "essentials" {
  cloud   = "GCP"
  region  = var.gcp_region
  package = "ESSENTIALS"
}
resource "confluent_schema_registry_cluster" "essentials" {
  package = data.confluent_schema_registry_region.essentials.package

  environment {
    id = confluent_environment.dezoom_project_env.id
  }

  region {
    # See https://docs.confluent.io/cloud/current/stream-governance/packages.html#stream-governance-regions
    id = data.confluent_schema_registry_region.essentials.id
  }
}

# Confluent Kafka Cluster
resource "confluent_kafka_cluster" "dezoom_kafka_cluster0" {
  display_name = "dezoom_kafka_cluster0"
  availability = "SINGLE_ZONE"
  cloud        = "GCP"
  region       = var.gcp_region
  basic {}

  environment {
    id = confluent_environment.dezoom_project_env.id
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Service account that will be used to manage the Kafka cluster 
resource "confluent_service_account" "dezoom_cluster_manager" {
  display_name = "dezoom_cluster_manager"
  description  = "Service account to manage Kafka cluster"
}

# Binds the service account to a CloudClusterAdmin role 
resource "confluent_role_binding" "dezoom_cluster_manager_kafka_admin" {
  principal   = "User:${confluent_service_account.dezoom_cluster_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.dezoom_kafka_cluster0.rbac_crn # cluster resource name (CRN) pattern
}

# Generates an API key for the service account
resource "confluent_api_key" "dezoom_cluster_manager_kafka_api_key" {
  display_name = "dezoom_cluster_manager_kafka_api_key"
  description  = "Kafka API Key that is owned by 'dezoom_cluster_manager' service account that has CloudClusterAdmin role"
  owner {
    id          = confluent_service_account.dezoom_cluster_manager.id
    api_version = confluent_service_account.dezoom_cluster_manager.api_version
    kind        = confluent_service_account.dezoom_cluster_manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dezoom_kafka_cluster0.id
    api_version = confluent_kafka_cluster.dezoom_kafka_cluster0.api_version
    kind        = confluent_kafka_cluster.dezoom_kafka_cluster0.kind

    environment {
      id = confluent_environment.dezoom_project_env.id
    }
  }

  # The goal is to ensure that confluent_role_binding.dezoom_cluster_manager_kafka_admin is created before
  # confluent_api_key.dezoom_cluster_manager_kafka_api_key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.

  # The 'depends_on' meta-argument ensures that the role binding is created before the API key, 
  # to prevent potential issues with permissions.
  # 'depends_on'=confluent_role_binding is specified inside api key resource scope (dezoom_cluster_manager_kafka_api_key) 
  # instead of inside confluent_kafka_topic, confluent_kafka_acl resources 
  # is to avoid having multiple copies of this definition in the configuration. 
  depends_on = [
    confluent_role_binding.dezoom_cluster_manager_kafka_admin
  ]
}

# Confluent Kafka Topic
resource "confluent_kafka_topic" "coinbase_avro" {
  kafka_cluster {
    id = confluent_kafka_cluster.dezoom_kafka_cluster0.id
  }
  topic_name       = "coinbase_avro"
  partitions_count = 4
  rest_endpoint    = confluent_kafka_cluster.dezoom_kafka_cluster0.rest_endpoint
  credentials {
    key    = confluent_api_key.dezoom_cluster_manager_kafka_api_key.id
    secret = confluent_api_key.dezoom_cluster_manager_kafka_api_key.secret
  }
}


# Confluent ksqlDB
# Binds the service account to a ResourceOwner role for Schema Registry Cluster: ksqlDB have restricted resource-level operations. 
# https://docs.confluent.io/platform/current/security/rbac/rbac-predefined-roles.html 
resource "confluent_role_binding" "dezoom_cluster_manager_schema_registry_resource_owner" {
  principal   = "User:${confluent_service_account.dezoom_cluster_manager.id}"
  role_name   = "ResourceOwner"
  crn_pattern = format("%s/%s", confluent_schema_registry_cluster.essentials.resource_name, "subject=*")

  # lifecycle {
  #   prevent_destroy = true
  # }
}
resource "confluent_ksql_cluster" "dezoom_transform_changes" {
  display_name = "dezoom_transform_changes"
  csu          = 1
  kafka_cluster {
    id = confluent_kafka_cluster.dezoom_kafka_cluster0.id
  }
  credential_identity {
    id = confluent_service_account.dezoom_cluster_manager.id
  }
  environment {
    id = confluent_environment.dezoom_project_env.id
  }
  depends_on = [
    confluent_role_binding.dezoom_cluster_manager_kafka_admin,
    confluent_role_binding.dezoom_cluster_manager_schema_registry_resource_owner,
    confluent_schema_registry_cluster.essentials
  ]

  # lifecycle {
  #   prevent_destroy = true
  # }
}



# Confluent Kafka BigQuery Connector
# connector.class=BigQueryStorageSink??
resource "confluent_connector" "bigquery-sink" {
  environment {
    id = confluent_environment.dezoom_project_env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.dezoom_kafka_cluster0.id
  }

  // Block for custom *sensitive* configuration properties that are labelled with "Type: password" under "Configuration Properties" section in the docs:
  // https://docs.confluent.io/cloud/current/connectors/cc-s3-sink.html#configuration-properties
  config_sensitive = {
    "keyfile" = file(var.gcp_credentials)
  }

  // Block for custom *nonsensitive* configuration properties that are *not* labelled with "Type: password" under "Configuration Properties" section in the docs:
  // https://docs.confluent.io/cloud/current/connectors/cc-s3-sink.html#configuration-properties
  config_nonsensitive = {
    "topics"                   = confluent_kafka_topic.coinbase_avro.topic_name
    "data.format"              = "AVRO"
    "connector.class"          = "BigQueryStorageSink"
    "name"                     = "BigQueryStorageSink_dezoom_project"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.dezoom_cluster_manager.id
    "project"                  = var.gcp_project
    "datasets"                 = var.gcp_dataset
    "tasks.max"                = "1"
    "auto.create.tables"       = "true"
  }
}

