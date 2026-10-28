# =====================================================================
# CREDPAY Keycloak - identity provider image for Kubernetes
# =====================================================================
# Official Keycloak + the CredPay login theme + the credpay realm, built
# once in CI and run unchanged in every environment (like the services).
#
#   - "kc.sh build" bakes the build-time options (PostgreSQL, health
#     endpoints) into the image, so pods start with --optimized (faster).
#   - The realm is imported on the first start only. Its portal URLs come
#     from CUSTOMER_PORTAL_URL / ADMIN_PORTAL_URL (see charts/credpay/templates/keycloak.yaml);
#     without them it falls back to the localhost URLs used on a laptop.
#
# Local development does not use this image: infra/docker-compose.yml runs
# the stock image in start-dev mode with the same theme and realm mounted.
# =====================================================================

# ---- Stage 1: build an optimized Keycloak ----------------------------
FROM quay.io/keycloak/keycloak:26.7.5 AS build

ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true

COPY themes/credpay /opt/keycloak/themes/credpay
RUN /opt/keycloak/bin/kc.sh build

# ---- Stage 2: runtime ------------------------------------------------
FROM quay.io/keycloak/keycloak:26.7.5

COPY --from=build /opt/keycloak/ /opt/keycloak/
COPY realm/credpay-realm.json /opt/keycloak/data/import/credpay-realm.json

# 8080 = HTTP (behind the ingress, which terminates TLS)
# 9000 = management: /health/ready, /health/live, /metrics
EXPOSE 8080 9000

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
