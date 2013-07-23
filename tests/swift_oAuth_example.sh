#!/bin/sh

# Keystone oAuth API example
# https://review.openstack.org/#/c/29130/39
# In this use case we illustrate access delegation to swift via oAuth.

# This script is expected to be run on a devstack-like install.
# keystone and swift must be running.

# add this to devstack/localrc to activate oAuth with keystone:
#KEYSTONE_TOKEN_FORMAT=PKI
#KEYSTONE_REPO=https://mhu@review.openstack.org/openstack/keystone
#KEYSTONE_BRANCH=refs/changes/30/29130/39

# also, oauth_service must be added manually to the v3 API pipeline in /etc/keystone/keystone-paste.ini
# change these to your own settings

TENANT_NAME=admin
USERNAME=admin
PASSWORD=admin

SERVICE_TOKEN=1234

# the script is run locally
URL=127.0.0.1

export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL=http://$URL:5000/v2.0

# Setting up the test environment

echo "** Create test tenant"

keystone tenant-create --name TestTenant1
# Get the tenants IDs
TENANT1=$(keystone tenant-get TestTenant1 |awk '{if ($2 == "id") {print $4}}')
MEMBER_ID=$(keystone role-get Member |awk '{if ($2 == "id") {print $4}}')
echo $MEMBER_ID
keystone role-create --name MyFancyRole
ROLE_ID=$(keystone role-get MyFancyRole |awk '{if ($2 == "id") {print $4}}')

echo "** Create test user"
keystone user-create --name User1 --tenant-id $TENANT1 --pass User1 --enabled true
# Get the users IDs
USER1=$(keystone user-get User1 |awk '{if ($2 == "id") {print $4}}')

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
#TOKEN1=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER1'", "password": "User1" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
TOKEN1=$(keystone --os-username User1 --os-tenant-name TestTenant1 --os-password User1 token-get |awk '{if ($2 == "id") {print $4}}')
#echo $TOKEN1

ADMIN_TOKEN=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "name": "'$USERNAME'", "password": "'$PASSWORD'", "domain" : { "name" : "default" } } } }, "scope": { "project": { "name": "admin", "domain": { "name" : "default" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
#ADMIN_TOKEN=$(keystone token-get |awk '{if ($2 == "id") {print $4}}')
#echo $ADMIN_TOKEN

echo "** Register as a Consumer"
CONSUMER=$(curl -H "X-Auth-Token: $ADMIN_TOKEN" -d '{ "consumer": { "name": "MyConsumer" } }' -H "Content-Type: application/json" http://$URL:5000/v3/OS-OAUTH10A/consumers)

echo $CONSUMER| python -mjson.tool

CONSUMER_ID=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["id"]' | col -b)
CONSUMER_KEY=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["consumer_key"]' | col -b)
CONSUMER_SECRET=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["consumer_secret"]' | col -b)

echo "** Make an access request for our Consumer"
# python to the rescue
REQUEST_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); client=oauth2.Client(consumer); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/request_token?requested_roles=Member"); print content')
REQUEST_TOKEN_KEY=$(echo $REQUEST_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["request_token_key"]' | col -b)
REQUEST_TOKEN_SECRET=$(echo $REQUEST_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["request_token_secret"]' | col -b)

echo $REQUEST_TOKEN| python -mjson.tool

# one has to be admin to authorize a request ? -Fixed in patch set 39
echo "** User1 gets the verifier PIN"
VERIFIER=$(curl -X POST -H "X-Auth-Token: $TOKEN1" http://$URL:5000/v3/OS-OAUTH10A/authorize/$REQUEST_TOKEN_KEY/Member)
echo $VERIFIER| python -mjson.tool
OAUTH_VERIFIER=$(echo $VERIFIER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["oauth_verifier"]' )

echo "** Validate access request with the verifier PIN"
ACCESS_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); token = oauth2.Token("'$REQUEST_TOKEN_KEY'", "'$REQUEST_TOKEN_SECRET'"); token.set_verifier("'$OAUTH_VERIFIER'");  client=oauth2.Client(consumer, token); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/access_token"); print content')
ACCESS_TOKEN_KEY=$(echo $ACCESS_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["access_token_key"]' | col -b)
ACCESS_TOKEN_SECRET=$(echo $ACCESS_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["access_token_secret"]' | col -b)
echo $ACCESS_TOKEN| python -mjson.tool


echo "** Fetch access token"
AUTH_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); token = oauth2.Token("'$ACCESS_TOKEN_KEY'", "'$ACCESS_TOKEN_SECRET'");   client=oauth2.Client(consumer, token); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/authenticate"); print content')
echo $AUTH_TOKEN| python -mjson.tool
TRUST_TOKEN=$(echo $AUTH_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["id"]' | col -b)


echo "** List items owned by User1 using the Trust token (cURL)"
curl -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff

#here the token fails to be linked to a tenant:
#proxy-server Using identity: {'roles': [u'MyFancyRole', u'_member_', u'Member'], 'user': u'User1', 'tenant': (None, None)} (txn: tx8caf73eeafe34aa59bb34-0051ecf844)
#proxy-server tenant mismatch: AUTH_4f3ab3d2319c49748361ec2b9be9f4cb != None (txn: tx8caf73eeafe34aa59bb34-0051ecf844) (client_ip: 127.0.0.1)
#proxy-server tenant mismatch: AUTH_4f3ab3d2319c49748361ec2b9be9f4cb != None (txn: tx8caf73eeafe34aa59bb34-0051ecf844) (client_ip: 127.0.0.1)


echo "** Do it again with the swift CLI"
unset OS_TENANT_NAME
unset OS_USERNAME
unset OS_PASSWORD
swift --os-auth-token $TRUST_TOKEN --os-storage-url http://$URL:8080/v1/AUTH_$TENANT1 -V 2 list stuff

echo "** Upload a file on behalf of User1"
curl -X PUT -T file3 -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff/file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 list stuff

echo "** Cleanup"
#TODO Cleanup Consumer and requests
curl -X DELETE -H "X-Auth-Token: $ADMIN_TOKEN" http://$URL:5000/v3/OS-OAUTH10A/consumers/$CONSUMER_ID
rm file1 file2 file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 delete stuff
export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
keystone user-delete User1
keystone role-delete MyFancyRole
keystone tenant-delete TestTenant1
