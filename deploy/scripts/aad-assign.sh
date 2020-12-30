1) Get accesstoken:
az account get-access-token --resource "https://graph.windows.net/"

2) Assign accessToken to variable
accessToken=<your access token>

3) Confirm access to graph.windows.net:
curl 'https://graph.windows.net/mytenant.onmicrosoft.com/users?api-version=1.6' -H "Authorization: Bearer $accessToken"

4) Assign object ID of service principal to variable objectID
objectID=<object ID>

5) Give permissions of 'Directory.Read.All' to the service prinicpal:
curl "https://graph.windows.net/mytenantonmicrosoft.com/servicePrincipals/$objectID/appRoleAssignments?api-version=1.6" -X POST -d '{"id":"5778995a-e1bf-45b8-affa-663a9f3f4d04","principalId":"$objectID","resourceId":"5e20606e-f80c-4695-9147-97a1fb962853"}' -H "Content-Type: application/json" -H "Authorization: Bearer $accessToken"

6) Test on VM:
curl 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&amp;resource=https://graph.windows.net' -H Metadata:true
accessToken=<accessToken>
curl 'https://graph.windows.net/mytenant.onmicrosoft.com/users?api-version=1.6' -H "Authorization: Bearer $accessToken"