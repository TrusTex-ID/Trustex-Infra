# Objective

The objective of this project is to create the Infrastructure using Terraform to deploy some services in GCP.

## Services to deploy

- Backend services (node.js) in a Cloud-Run
- Java services, (springboot) in a Cloud-Run
- Frontend services (next.js) in a Cloud-Run
- Postgres database in Cloud SQL
- Artifact registry to upload the docker images for the different services

Include other services you consider imprescindible like load balancer, SSL certificates, and so on.

## Expected budget

- No more than 20$ or 25$ per month

## Files organization

- Must have clear files separation for each config type in Terraform. For example one cloudRun.tf for cloudRun config, database.tf for database config and so on.

