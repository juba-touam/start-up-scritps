#!/bin/bash


HOSTNAME=$(hostname)


if [[ "$HOSTNAME" == *"dev"* ]]; then

   if [[ "$HOSTNAME" == *"back"* ]]; then
       export CATALOGUE_IMAGE=crformation.azurecr.io/ecommerce-catalogue
       export CATALOGUE_TAG=1.0
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
       export ORDER_TAG=1.0
       export ORDER_DJANGO_SECRET_KEY=prod-secret-key-change-me
       export ORDER_DJANGO_SETTINGS_MODULE=config.settings.prod
       export ORDER_POSTGRES_DB=order
       export ORDER_POSTGRES_USER=formation
       export ORDER_POSTGRES_PASSWORD=test
       export ORDER_POSTGRES_HOST=data-pgsql-dev.postgres.database.azure.com
       export ORDER_POSTGRES_PORT=5432
       export POSTGRES_SSLMODE=require

       export PAYMENT_IMAGE=crformation.azurecr.io/ecommerce-payment
       export PAYMENT_TAG=1.0
       # shellcheck disable=SC2125
       export PAYMENT_SPRING_DATASOURCE_URL=jdbc:postgresql://data-pgsql-dev.postgres.database.azure.com:5432/payment?sslmode=require
       export PAYMENT_SPRING_DATASOURCE_USERNAME=formation
       export PAYMENT_SPRING_DATASOURCE_PASSWORD=test

   elif [[ "$HOSTNAME" == *"front"* ]]; then
       export FRONTEND_IMAGE=crformation.azurecr.io/ecommerce-front
       export FRONTEND_TAG=3.0
       export FRONTEND_CATALOG=http://20.111.59.49/api/products
       export FRONTEND_ORDERS=http://20.111.59.49/api/orders
       export FRONTEND_PAYMENT=http://20.111.59.49/api/payments
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
           echo "VM frontend détectée — démarrage du frontend uniquement..."
           docker compose -f docker-compose.front.yaml up -d
       else
           echo "VM backend détectée — démarrage des services backend uniquement..."
           docker compose -f docker-compose.back.yaml up -d
       fi
       ;;

esac

