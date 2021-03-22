// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace IIoTPlatform_E2E_Tests.Orchestrated
{
    using System;
    using System.Linq;
    using System.Threading.Tasks;
    using Xunit;
    using Newtonsoft.Json;
    using RestSharp;
    using TestExtensions;
    using Xunit.Abstractions;
    using System.Threading;
    using System.Collections.Generic;

    /// <summary>
    /// The test theory using different (ordered) test cases to go thru all required steps of publishing OPC UA node
    /// </summary>
    [TestCaseOrderer(TestCaseOrderer.FullName, TestConstants.TestAssemblyName)]
    [Collection("IIoT Multiple Nodes Test Collection")]
    [Trait(TestConstants.TraitConstants.PublisherModeTraitName, TestConstants.TraitConstants.PublisherModeOrchestratedTraitValue)]
    public class A_PublishSingleNodeOrchestratedTestTheory
    {
        private readonly ITestOutputHelper _output;
        private readonly IIoTMultipleNodesTestContext _context;

        public A_PublishSingleNodeOrchestratedTestTheory(IIoTMultipleNodesTestContext context, ITestOutputHelper output) {
            _output = output ?? throw new ArgumentNullException(nameof(output));
            _context = context ?? throw new ArgumentNullException(nameof(context));
            _context.OutputHelper = _output;
        }

        [Fact, PriorityOrder(0)]
        public void Test_SetUnmanagedTagFalse() {
            _context.Reset();
            TestHelper.SwitchToOrchestratedModeAsync(_context).GetAwaiter().GetResult();
        }

        [Fact, PriorityOrder(1)]
        public void Test_CollectOAuthToken() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var token = TestHelper.GetTokenAsync(_context, cts.Token).GetAwaiter().GetResult();
            Assert.NotEmpty(token);
        }

        [Fact, PriorityOrder(2)]
        public void Test_ReadSimulatedOpcUaNodes() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var simulatedOpcServer = TestHelper.GetSimulatedPublishedNodesConfigurationAsync(_context, cts.Token).GetAwaiter().GetResult();
            Assert.NotNull(simulatedOpcServer);
            Assert.NotEmpty(simulatedOpcServer.Keys);
            Assert.NotEmpty(simulatedOpcServer.Values);
        }

        [Fact, PriorityOrder(3)]
        public void Test_RegisterOPCServer_Expect_Success() {

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);

            // We will wait for microservices of IIoT platform to be healthy and modules to be deployed.
            TestHelper.WaitForServicesAsync(_context, cts.Token).GetAwaiter().GetResult();
            _context.RegistryHelper.WaitForIIoTModulesConnectedAsync(_context.DeviceConfig.DeviceId, cts.Token).GetAwaiter().GetResult();

            var simulatedOpcServer = TestHelper.GetSimulatedPublishedNodesConfigurationAsync(_context, cts.Token).GetAwaiter().GetResult();
            var body = new {
                discoveryUrl = simulatedOpcServer.Values.First().EndpointUrl
            };

            var route = TestConstants.APIRoutes.RegistryApplications;
            var response = TestHelper.CallRestApi(_context, Method.POST, route, body, ct: cts.Token);
            Assert.True(response.IsSuccessful);
        }

        [Fact, PriorityOrder(4)]
        public void Test_GetApplicationsFromRegistry_ExpectOneRegisteredApplication() {

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var simulatedOpcServer = TestHelper.GetSimulatedPublishedNodesConfigurationAsync(_context, cts.Token).GetAwaiter().GetResult();
            var testPlc = simulatedOpcServer.Values.First();
            _context.ConsumedOpcUaNodes[testPlc.EndpointUrl] = _context.GetEntryModelWithoutNodes(testPlc);
            dynamic json = TestHelper.Discovery.WaitForDiscoveryToBeCompletedAsync(_context, cts.Token, new List<string> { testPlc.EndpointUrl }).GetAwaiter().GetResult();

            var numberOfItems = (int)json.items.Count;
            bool found = false;
            for (int indexOfTestPlc = 0; indexOfTestPlc < numberOfItems; indexOfTestPlc++) {

                var endpoint = ((string)json.items[indexOfTestPlc].discoveryUrls[0]).TrimEnd('/');
                if (endpoint == testPlc.EndpointUrl) {
                    found = true;

                    break;
                }
            }
            Assert.True(found, "OPC Application not activated");
        }

        [Fact, PriorityOrder(5)]
        public void Test_GetEndpoints_Expect_OneWithMultipleAuthentication() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var testPlc = _context.ConsumedOpcUaNodes.First().Value;
            var json = TestHelper.Discovery.WaitForEndpointDiscoveryToBeCompleted(_context, cts.Token, new List<string> { testPlc.EndpointUrl }).GetAwaiter().GetResult();

            var numberOfItems = (int)json.items.Count;
            bool found = false;
            for (int indexOfOpcUaEndpoint = 0; indexOfOpcUaEndpoint < numberOfItems; indexOfOpcUaEndpoint++) {

                var endpoint = ((string)json.items[indexOfOpcUaEndpoint].registration.endpointUrl).TrimEnd('/');
                if (endpoint == testPlc.EndpointUrl) {
                    found = true;

                    // Authentication Checks
                    var id = (string)json.items[indexOfOpcUaEndpoint].registration.id;
                    Assert.NotEmpty(id);
                    var securityMode = (string)json.items[indexOfOpcUaEndpoint].registration.endpoint.securityMode;
                    Assert.Equal("SignAndEncrypt", securityMode);
                    var authenticationModeNone = (string)json.items[indexOfOpcUaEndpoint].registration.authenticationMethods[0].credentialType;
                    Assert.Equal("None", authenticationModeNone);
                    var authenticationModeUserName = (string)json.items[indexOfOpcUaEndpoint].registration.authenticationMethods[1].credentialType;
                    Assert.Equal("UserName", authenticationModeUserName);
                    var authenticationModeCertificate = (string)json.items[indexOfOpcUaEndpoint].registration.authenticationMethods[2].credentialType;
                    Assert.Equal("X509Certificate", authenticationModeCertificate);

                    // Store id of endpoint for further interaction
                    _context.OpcUaEndpointId = id;
                    break;
                }
            }
            Assert.True(found, "OPC UA Endpoint not found");
        }

        [Fact, PriorityOrder(6)]
        public void Test_ActivateEndpoint_Expect_Success() {

            // Used if running test cases separately (during development)
            if (string.IsNullOrWhiteSpace(_context.OpcUaEndpointId)) {
                Test_GetEndpoints_Expect_OneWithMultipleAuthentication();
                Assert.False(string.IsNullOrWhiteSpace(_context.OpcUaEndpointId));
            }

            TestHelper.Registry.ActivateEndpointAsync(_context, _context.OpcUaEndpointId).GetAwaiter().GetResult();
        }

        [Fact, PriorityOrder(7)]
        public void Test_CheckIfEndpointWasActivated_Expect_ActivatedAndConnected() {

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var testPlc = _context.ConsumedOpcUaNodes.First().Value;
            var json = TestHelper.Registry.WaitForEndpointToBeActivatedAsync(_context, cts.Token, new List<string> { testPlc.EndpointUrl }).GetAwaiter().GetResult();

            var numberOfItems = (int)json.items.Count;
            bool found = false;
            for (int indexOfOpcUaEndpoint = 0; indexOfOpcUaEndpoint < numberOfItems; indexOfOpcUaEndpoint++) {

                var endpoint = ((string)json.items[indexOfOpcUaEndpoint].registration.endpointUrl).TrimEnd('/');
                if (endpoint == testPlc.EndpointUrl) {
                    found = true;

                    var endpointState = (string)json.items[indexOfOpcUaEndpoint].endpointState;
                    Assert.Equal("Ready", endpointState);
                    break;
                }
            }
            Assert.True(found, "OPC UA Endpoint not found");
        }

        [Fact, PriorityOrder(8)]
        public void Test_PublishNodeWithDefaults_Expect_DataAvailableAtIoTHub() {

            // Used if running test cases separately (during development)
            if (string.IsNullOrWhiteSpace(_context.OpcUaEndpointId)) {
                Test_GetEndpoints_Expect_OneWithMultipleAuthentication();
                Assert.False(string.IsNullOrWhiteSpace(_context.OpcUaEndpointId));
            }

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var simulatedOpcServer = TestHelper.GetSimulatedPublishedNodesConfigurationAsync(_context, cts.Token).GetAwaiter().GetResult();

            var route = string.Format(TestConstants.APIRoutes.PublisherStartFormat, _context.OpcUaEndpointId);
            var body = new {
                item = new {
                    nodeId = simulatedOpcServer.Values.First().OpcNodes.First().Id,
                    samplingInterval = "00:00:00.250",
                    publishingInterval = "00:00:00.500",
                }
            };

            var response = TestHelper.CallRestApi(_context, Method.POST, route, body, ct: cts.Token);
            Assert.Equal("{}",response.Content);
        }

        [Fact, PriorityOrder(9)]
        public void Test_GetListOfJobs_Expect_OneJobWithPublishingOneNode() {

            // Used if running test cases separately (during development)
            if (string.IsNullOrWhiteSpace(_context.OpcUaEndpointId)) {
                Test_GetEndpoints_Expect_OneWithMultipleAuthentication();
                Assert.False(string.IsNullOrWhiteSpace(_context.OpcUaEndpointId));
            }

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var simulatedOpcServer = TestHelper.GetSimulatedPublishedNodesConfigurationAsync(_context, cts.Token).GetAwaiter().GetResult();
            var route = TestConstants.APIRoutes.PublisherJobs;
            var response = TestHelper.CallRestApi(_context, Method.GET, route, ct: cts.Token);
            dynamic json = JsonConvert.DeserializeObject(response.Content);

            var count = (int)json.jobs.Count;
            Assert.NotEqual(0, count);
            Assert.NotNull(json.jobs[0].jobConfiguration);
            Assert.NotNull(json.jobs[0].jobConfiguration.writerGroup);
            Assert.NotNull(json.jobs[0].jobConfiguration.writerGroup.dataSetWriters);
            count = (int)json.jobs[0].jobConfiguration.writerGroup.dataSetWriters.Count;
            Assert.Equal(1, count);
            Assert.NotNull(json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet);
            Assert.NotNull(json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet.dataSetSource);
            Assert.NotNull(json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet.dataSetSource.publishedVariables.publishedData);
            count = (int)json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet.dataSetSource.publishedVariables.publishedData.Count;
            Assert.Equal(1, count);
            Assert.NotEmpty((string)json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet.dataSetSource.publishedVariables.publishedData[0].publishedVariableNodeId);
            var publishedNodeId = (string)json.jobs[0].jobConfiguration.writerGroup.dataSetWriters[0].dataSet.dataSetSource.publishedVariables.publishedData[0].publishedVariableNodeId;
            Assert.Equal(simulatedOpcServer.Values.First().OpcNodes.First().Id, publishedNodeId);
        }

        [Fact, PriorityOrder(10)]
        public void Test_VerifyDataAvailableAtIoTHub() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);

            // Use test event processor to verify data send to IoT Hub (expected* set to zero as data gap analysis is not part of this test case)
            TestHelper.StartMonitoringIncomingMessagesAsync(_context, 0, 0, 0, cts.Token).GetAwaiter().GetResult();
            // Wait some time to generate events to process
            Task.Delay(TestConstants.DefaultTimeoutInMilliseconds, cts.Token).GetAwaiter().GetResult();
            var json = TestHelper.StopMonitoringIncomingMessagesAsync(_context, cts.Token).GetAwaiter().GetResult();
            Assert.True((int)json.totalValueChangesCount > 0, "No messages received at IoT Hub");
            Assert.True((uint)json.droppedValueCount == 0, "Dropped messages detected");
            Assert.True((uint)json.duplicateValueCount == 0, "Duplicate values detected");
        }

        [Fact, PriorityOrder(11)]
        public void RemoveJob_Expect_Success() {
            // used if running test cases separately (during development)
            if (string.IsNullOrWhiteSpace(_context.OpcUaEndpointId)) {
                Test_GetEndpoints_Expect_OneWithMultipleAuthentication();
                Assert.False(string.IsNullOrWhiteSpace(_context.OpcUaEndpointId));
            }

            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var route = string.Format(TestConstants.APIRoutes.PublisherJobsFormat, _context.OpcUaEndpointId);
            TestHelper.CallRestApi(_context, Method.DELETE, route, ct: cts.Token);
        }

        [Fact, PriorityOrder(12)]
        public void Test_VerifyNoDataIncomingAtIoTHub() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            Task.Delay(TestConstants.DefaultTimeoutInMilliseconds, cts.Token).GetAwaiter().GetResult(); // wait until the publishing has stopped
            // Use test event processor to verify data send to IoT Hub (expected* set to zero as data gap analysis is not part of this test case)
            TestHelper.StartMonitoringIncomingMessagesAsync(_context, 0, 0, 0, cts.Token).GetAwaiter().GetResult();
            // Wait some time to generate events to process
            Task.Delay(TestConstants.DefaultTimeoutInMilliseconds, cts.Token).GetAwaiter().GetResult();
            var json = TestHelper.StopMonitoringIncomingMessagesAsync(_context, cts.Token).GetAwaiter().GetResult();
            Assert.True((int)json.totalValueChangesCount == 0, "Messages received at IoT Hub");
        }

        [Fact, PriorityOrder(13)]
        public void Test_RemoveAllApplications() {
            var cts = new CancellationTokenSource(TestConstants.MaxTestTimeoutMilliseconds);
            var route = TestConstants.APIRoutes.RegistryApplications;
            TestHelper.CallRestApi(_context, Method.DELETE, route, ct: cts.Token);
        }
    }
}
