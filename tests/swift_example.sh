#!/bin/sh

# Keystone Trusts API example
# https://github.com/openstack/identity-api/blob/master/openstack-identity-api/v3/src/markdown/identity-api-v3-os-trust-ext.md
# In this use case we illustrate access delegation to swift via a trust.

# This script is expected to be run on a devstack-like install.
# keystone and swift must be running.

# change these to your own settings

TENANT_NAME=admin
USERNAME=admin
PASSWORD=admin

# the script is run locally
URL=127.0.0.1

export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL=http://$URL:5000/v2.0

# Setting up the test environment

echo "** Create test tenants"

keystone tenant-create --name TestTenant1
keystone tenant-create --name TestTenant2
# Get the tenants IDs
TENANT1=$(keystone tenant-get TestTenant1 |awk '{if ($2 == "id") {print $4}}')
TENANT2=$(keystone tenant-get TestTenant2 |awk '{if ($2 == "id") {print $4}}')
MEMBER_ID=$(keystone role-get Member |awk '{if ($2 == "id") {print $4}}')
keystone role-create --name MyFancyRole
ROLE_ID=$(keystone role-get MyFancyRole |awk '{if ($2 == "id") {print $4}}')

echo "** Create test users"
keystone user-create --name User1 --tenant-id $TENANT1 --pass User1 --enabled true
keystone user-create --name User2 --tenant-id $TENANT2 --pass User2 --enabled true
# Get the users IDs
USER1=$(keystone user-get User1 |awk '{if ($2 == "id") {print $4}}')
USER2=$(keystone user-get User2 |awk '{if ($2 == "id") {print $4}}')

echo "** Allow User1 to do stuff on swift"
keystone user-role-add --user-id $USER1 --role-id $MEMBER_ID --tenant-id $TENANT1
# Add the extra role to single out accesses from the delegate and the real deal
keystone user-role-add --user-id $USER1 --role-id $ROLE_ID --tenant-id $TENANT1

echo "** Upload stuff as User1"
echo "this is file1" > file1
echo "this is file2" > file2
echo "this is file3" > file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 upload stuff file1 file2

echo "** Get V3 tokens" 
# cannot use V2 tokens with trusts, even though it should be possible
# see: https://bugs.launchpad.net/keystone/+bug/1182448
TOKEN1=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER1'", "password": "User1" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
TOKEN2=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER2'", "password": "User2" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
echo $TOKEN2

echo "** Create trust: Trustor User1, Trustee User2, role delegation: Member"
TRUST=$(curl -H "X-Auth-Token: $TOKEN1" -d '{ "trust": { "expires_at": "2024-02-27T18:30:59.999999Z", "impersonation": false, "project_id": "'$TENANT1'", "roles": [ { "name": "Member" } ], "trustee_user_id": "'$USER2'", "trustor_user_id": "'$USER1'" }}' -H "Content-type: application/json" http://$URL:35357/v3/OS-TRUST/trusts)
echo $TRUST| python -mjson.tool
TRUST_ID=$(echo $TRUST| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["trust"]["id"]' | col -b)
#echo $TRUST_ID

echo "** Get Trust token"
TRUST_JSON='{ "auth" : { "identity" : { "methods" : [ "token" ], "token" : { "id" : "'$TOKEN2'" } }, "scope" : { "OS-TRUST:trust" : { "id" : "'$TRUST_ID'" } } } }'
#echo $TRUST_JSON | python -mjson.tool
#TRUST_CONSUME=$(curl -i -d "$TRUST_JSON" -H "Content-type: application/json" http://$URL:35357/v3/auth/tokens)
#echo $TRUST_CONSUME
TRUST_TOKEN=$(curl -i -d "$TRUST_JSON" -H "Content-type: application/json" http://$URL:35357/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}')
echo $TRUST_TOKEN

echo "** List items owned by User1 using the Trust token (cURL)"
curl -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff

# Excerpt from the swift server proxy logs:
#
#proxy-server Storing $TRUST_TOKEN token in memcache
#proxy-server STDOUT: WARNING:root:parameter timeout has been deprecated, use time (txn: txedd37c6afd9246459d1cf-0051e41204)
#proxy-server Using identity: {'roles': [u'Member'], 'user': u'User2', 'tenant': (u'58aa10296ed94ea696a83817e43f6d40', u'TestTenant1')} (txn: txedd37c6afd9246459d1cf-0051e41204)
#
# If impersonation was set to true, the user would appear as User1, with restricted roles

echo "** Do it again with the swift CLI"
unset OS_TENANT_NAME
unset OS_USERNAME
unset OS_PASSWORD
swift --os-auth-token $TRUST_TOKEN --os-storage-url http://$URL:8080/v1/AUTH_$TENANT1 -V 2 list stuff

echo "** Upload a file on behalf of User1"
curl -X PUT -T file3 -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff/file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 list stuff

echo "** Cleanup"
rm file1 file2 file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 delete stuff
export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
keystone user-delete User1
keystone user-delete User2
keystone role-delete MyFancyRole
keystone tenant-delete TestTenant1
keystone tenant-delete TestTenant2
