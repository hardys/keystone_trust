#!/bin/sh

# Keystone Trusts API example
# https://github.com/openstack/identity-api/blob/master/openstack-identity-api/v3/src/markdown/identity-api-v3-os-trust-ext.md
# In this use case we illustrate creating a trust and consuming it

# the script is run locally
URL=127.0.0.1

# export these in your environment, or set them here
#export OS_TENANT_NAME=$TENANT_NAME
#export OS_USERNAME=$USERNAME
#export OS_PASSWORD=$PASSWORD
#export OS_AUTH_URL=http://$URL:5000/v2.0

# Setting up the test environment

echo "** Create test tenants"

#keystone tenant-create --name TestTenant1
#keystone tenant-create --name TestTenant2
# Get the tenants IDs
TENANT1=$(keystone tenant-get TestTenant1 |awk '{if ($2 == "id") {print $4}}')
TENANT2=$(keystone tenant-get TestTenant2 |awk '{if ($2 == "id") {print $4}}')
MEMBER_ID=$(keystone role-get Member |awk '{if ($2 == "id") {print $4}}')
#keystone role-create --name MyFancyRole
ROLE_ID=$(keystone role-get MyFancyRole |awk '{if ($2 == "id") {print $4}}')

echo "** Create test users"
#keystone user-create --name User1 --tenant-id $TENANT1 --pass User1 --enabled true
#keystone user-create --name User2 --tenant-id $TENANT2 --pass User2 --enabled true
# Get the users IDs
USER1=$(keystone user-get User1 |awk '{if ($2 == "id") {print $4}}')
USER2=$(keystone user-get User2 |awk '{if ($2 == "id") {print $4}}')

echo "keystone user-role-add --user-id USER1 --role-id MEMBER --tenant-id TENANT1"
keystone user-role-add --user-id $USER1 --role-id $MEMBER_ID --tenant-id $TENANT1
# Add the extra role to single out accesses from the delegate and the real deal
keystone user-role-add --user-id $USER1 --role-id $ROLE_ID --tenant-id $TENANT1

echo "** Get V3 tokens" 
# cannot use V2 tokens with trusts, even though it should be possible
# see: https://bugs.launchpad.net/keystone/+bug/1182448
TOKEN1=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER1'", "password": "User1" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
TOKEN2=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER2'", "password": "User2" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
#echo $TOKEN2

echo "** Create trust: Trustor User1, Trustee User2, role delegation: Member"
echo "curl -H 'X-Auth-Token: USER1_TOKEN' -d 
'{ \"trust\":
    { \"expires_at\": \"2024-02-27T18:30:59.999999Z\",
      \"impersonation\": false,
      \"project_id\": \"TENANT1\",
      \"roles\": [ { \"name\": \"Member\" } ],
      \"trustee_user_id\": \"USER2\",
      \"trustor_user_id\": \"USER1\" }
}' -H 'Content-type: application/json' http://$URL:35357/v3/OS-TRUST/trusts"
TRUST=$(curl -H "X-Auth-Token: $TOKEN1" -d '{ "trust": { "expires_at": "2024-02-27T18:30:59.999999Z", "impersonation": false, "project_id": "'$TENANT1'", "roles": [ { "name": "Member" } ], "trustee_user_id": "'$USER2'", "trustor_user_id": "'$USER1'" }}' -H "Content-type: application/json" http://$URL:35357/v3/OS-TRUST/trusts)
echo ">>>"
echo $TRUST| python -mjson.tool
TRUST_ID=$(echo $TRUST| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["trust"]["id"]' | col -b)
echo $TRUST_ID

echo "** Get v2 token"
V2_JSON='{"auth": {"tenantName": "TestTenant2", "passwordCredentials": {"username": "User2", "password": "User2"}}}'
#TRUST_JSON='{"auth": {"tenantName": "TestTenant2", "passwordCredentials": {"username": "User2", "password": "User2"}}}'
##TRUST_JSON='{ "auth" : { "identity" : { "methods" : [ "token" ], "token" : { "id" : "'$TOKEN2'" } }, "scope" : { "OS-TRUST:trust" : { "id" : "'$TRUST_ID'" } } } }'
echo $V2_JSON| python -mjson.tool
V2_RESP=$(curl -i -d "$V2_JSON" -H "Content-type: application/json" http://$URL:35357/v2.0/tokens | grep "^{")
echo "V2_RESP=$V2_RESP"
V2_TOKEN=$(echo $V2_RESP | python -c 'import json,sys; obj=json.load(sys.stdin); print obj["access"]["token"]["id"]' | col -b)
echo "V2_TOKEN=$V2_TOKEN"

echo "** Get v2 Trust token"
TRUST_JSON='{"auth": {"token": {"id": "'$V2_TOKEN'"}, "trust_id":"'$TRUST_ID'", "tenantId":"'$TENANT1'"}}'
#TRUST_JSON='{"auth": {"token": {"id": "'$V2_TOKEN'"}, "trust_id":"'$TRUST_ID'"}}'
##TRUST_JSON='{ "auth" : { "identity" : { "methods" : [ "token" ], "token" : { "id" : "'$TOKEN2'" } }, "scope" : { "OS-TRUST:trust" : { "id" : "'$TRUST_ID'" } } } }'
echo $TRUST_JSON| python -mjson.tool
TRUST_CONSUME=$(curl -i -d "$TRUST_JSON" -H "Content-type: application/json" http://$URL:35357/v2.0/tokens)
echo "TRUST_CONSUME=$TRUST_CONSUME"

