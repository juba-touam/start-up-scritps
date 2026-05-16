#!/bin/bash


HOSTNAME=$(hostname)


if [[ "$HOSTNAME" == *"dev"* ]]; then

   if [[ "$HOSTNAME" == *"back"* ]]; then
       export CATALOGUE_IMAGE=crformation.azurecr.io/ecommerce-catalogue
       export CATALOGUE_TAG=2.0
       export CATALOGUE_PORT=4000
       export CATALOGUE_NODE_ENV=production
       export CATALOGUE_DB_HOST=data-pgsql-dev.postgres.database.azure.com
       export CATALOGUE_DB_PORT=5432
       export CATALOGUE_DB_NAME=catalogue
       export CATALOGUE_DB_USER=formation
       export CATALOGUE_DB_PASSWORD=test
       export DB_SSL=true
       export PGSSLMODE=require

       export ORDER_IMAGE=crformation.azurecr.io/ecommerce-order
       export ORDER_TAG=2.0
       export ORDER_DJANGO_SECRET_KEY=prod-secret-key-change-me
       export ORDER_DJANGO_SETTINGS_MODULE=config.settings.prod
       export ORDER_POSTGRES_DB=order
       export ORDER_POSTGRES_USER=formation
       export ORDER_POSTGRES_PASSWORD=test
       export ORDER_POSTGRES_HOST=data-pgsql-dev.postgres.database.azure.com
       export ORDER_POSTGRES_PORT=5432
       export POSTGRES_SSLMODE=require

       export PAYMENT_IMAGE=crformation.azurecr.io/ecommerce-payment
       export PAYMENT_TAG=2.0
       # shellcheck disable=SC2125
       export PAYMENT_SPRING_DATASOURCE_URL=jdbc:postgresql://data-pgsql-dev.postgres.database.azure.com:5432/payment?sslmode=require
       export PAYMENT_SPRING_DATASOURCE_USERNAME=formation
       export PAYMENT_SPRING_DATASOURCE_PASSWORD=test

       # Application Insights
       export APPLICATIONINSIGHTS_CONNECTION_STRING="InstrumentationKey=1311ad53-6ac0-4946-bb2f-48c60120bbd9;IngestionEndpoint=https://francecentral-1.in.applicationinsights.azure.com/;LiveEndpoint=https://francecentral.livediagnostics.monitor.azure.com/;ApplicationId=d9efc03e-0523-42cc-9e0e-1ea237ed1ba4"

   elif [[ "$HOSTNAME" == *"front"* ]]; then
       export FRONTEND_IMAGE=crformation.azurecr.io/ecommerce-front
       export FRONTEND_TAG=5.0
       export FRONTEND_CATALOG=https://ecom-apim-formation.azure-api.net/api/products
       export FRONTEND_ORDERS=https://ecom-apim-formation.azure-api.net/api/orders
       export FRONTEND_PAYMENT=https://ecom-apim-formation.azure-api.net/api/payments
       export FRONTEND_KEYCLOAK_URL=https://ecom-apim-formation.azure-api.net/auth
       export FRONTEND_KEYCLOAK_REALM=user
       export FRONTEND_KEYCLOAK_CLIENT_ID=ecom-frontend
   fi


elif [[ "$HOSTNAME" == *"qua"* ]]; then

   if [[ "$HOSTNAME" == *"back"* ]]; then

       export CATALOGUE_TAG=qualif


   elif [[ "$HOSTNAME" == *"front"* ]]; then

       export FRONTEND_TAG=qualif

   fi
 


elif [[ "$HOSTNAME" == *"prod"* ]]; then

   if [[ "$HOSTNAME" == *"back"* ]]; then

       export CATALOGUE_TAG=prod



   elif [[ "$HOSTNAME" == *"front"* ]]; then

       export FRONTEND_TAG=prod

   fi


fi


# ── Sélection des services à démarrer ────────────────────────

#BACKEND_SERVICES="catalogue-db orders-db payment-db catalogue-service order-service payment-service"

#FRONTEND_SERVICES="frontend nginx-proxy"


ACR_NAME="crformation"

# 1. Token AAD depuis IMDS
ACCESS_TOKEN=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" \
  | jq -r .access_token)

# 2. Échange contre refresh token ACR
ACR_TOKEN=$(curl -s -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=access_token&service=${ACR_NAME}.azurecr.io&access_token=${ACCESS_TOKEN}" \
  "https://${ACR_NAME}.azurecr.io/oauth2/exchange" \
  | jq -r .refresh_token)

# 3. Login Docker (le username 00...00 est une convention ACR)
echo "$ACR_TOKEN" | docker login "${ACR_NAME}.azurecr.io" \
  --username 00000000-0000-0000-0000-000000000000 \
  --password-stdin



case "$1" in
   delete)
       docker compose rm -sf "$2"
       ;;
   restart)
       docker compose restart "$2"
       ;;
   *)
       if [[ "$HOSTNAME" == *"front"* ]]; then
           # Récupération du certificat TLS depuis Key Vault via IMDS
           VAULT_NAME="kv-formation-security"
           CERT_NAME="front-tls"
           CERT_DIR="/opt/certs"
           mkdir -p "$CERT_DIR"

           KV_CLIENT_ID=$(curl -s -H "Metadata: true" \
             "http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01" \
             | jq -r '.[] | select(.name=="kv_identity_client_id") | .value')

           KV_TOKEN=$(curl -s -H "Metadata: true" \
             "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${KV_CLIENT_ID}" \
             | jq -r .access_token)

           PEM_BUNDLE=$(curl -s -H "Authorization: Bearer ${KV_TOKEN}" \
             "https://${VAULT_NAME}.vault.azure.net/secrets/${CERT_NAME}?api-version=7.4" \
             | jq -r .value)

           echo "$PEM_BUNDLE" | openssl pkey -out "$CERT_DIR/tls.key" 2>/dev/null
           echo "$PEM_BUNDLE" | openssl x509 -out "$CERT_DIR/tls.crt" 2>/dev/null
           chmod 600 "$CERT_DIR/tls.key"
           echo "Certificat TLS récupéré depuis Key Vault."

           echo "VM frontend détectée — démarrage du frontend uniquement..."
           docker compose -f docker-compose.front.yaml up -d
       else
           echo "VM backend détectée — démarrage des services backend uniquement.."
           docker compose -f docker-compose.back.yaml up -d
       fi
       ;;

esac