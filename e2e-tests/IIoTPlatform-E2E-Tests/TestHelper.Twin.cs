// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace IIoTPlatform_E2E_Tests {
    using IIoTPlatform_E2E_Tests.TestExtensions;
    using Newtonsoft.Json;
    using Newtonsoft.Json.Converters;
    using RestSharp;
    using System;
    using System.Collections.Concurrent;
    using System.Collections.Generic;
    using System.Dynamic;
    using System.Linq;
    using System.Threading;
    using Xunit;

    internal static partial class TestHelper {

        /// <summary>
        /// Twin related helper methods
        /// </summary>
        public static class Twin {

            /// <summary>
            /// Equivalent to GetSetOfUniqueNodesAsync
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="nodeId">Id of the parent node or null to browse the root node</param>
            /// <param name="ct">Cancellation token</param>
            public static List<(string NodeId, string NodeClass, bool Children)> GetBrowseEndpoint(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string nodeId = null,
                    CancellationToken ct = default) {

                if (string.IsNullOrEmpty(endpointId)) {
                    context.OutputHelper.WriteLine($"{nameof(endpointId)} is null or empty");
                    throw new ArgumentNullException(nameof(endpointId));
                }

                var result = new List<(string NodeId, string NodeClass, bool Children)>();
                string continuationToken = null;

                do {
                    var browseResult = GetBrowseEndpoint_Internal(context, endpointId, nodeId, continuationToken, ct);

                    if (browseResult.results.Count > 0) {
                        result.AddRange(browseResult.results);
                    }

                    continuationToken = browseResult.continuationToken;
                } while (continuationToken != null);

                return result;
            }

            /// <summary>
            /// Calls a GET twin browse with the given <paramref name="endpointId"/>
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="nodeId">Id of the parent node or null to browse the root node</param>
            /// <param name="continuationToken">Continuation token from the previous call, or null</param>
            /// <param name="ct">Cancellation token</param>
            private static (List<(string NodeId, string NodeClass, bool Children)> results, string continuationToken) GetBrowseEndpoint_Internal(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string nodeId = null,
                    string continuationToken = null,
                    CancellationToken ct = default) {

                string route = $"twin/v2/browse/{endpointId}";
                Dictionary<string, string> queryParameters = null;
                if (continuationToken == null) {
                    if (!string.IsNullOrEmpty(nodeId)) {
                        queryParameters = new Dictionary<string, string> { { "nodeId", nodeId } };
                    }
                }
                else {
                    route += "/next";
                    queryParameters = new Dictionary<string, string> { { "continuationToken", continuationToken } };
                }

                var response = CallRestApi(context, Method.GET, route, queryParameters: queryParameters, ct: ct);
                dynamic json = JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());

                Assert.True(HasProperty(json, "references"), "GET twin/v2/browse/{endpointId} response has no items");
                Assert.False(json.references == null, "GET twin/v2/browse/{endpointId} response references property is null");

                var result = new List<(string NodeId, string NodeClass, bool Children)>();

                foreach (var node in json.references) {
                    result.Add(
                        (
                            node.target?.nodeId?.ToString(),
                            node.target?.nodeClass?.ToString(),
                            string.Equals(node.target?.children?.ToString(), "true", StringComparison.OrdinalIgnoreCase)));
                }

                var responseContinuationToken = HasProperty(json, "continuationToken") ? json.continuationToken : null;

                return (results: result, continuationToken: responseContinuationToken);
            }

            /// <summary>
            /// Equivalent to recursive calling GetSetOfUniqueNodesAsync to get the whole hierarchy of nodes
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="nodeClass">Class of the node to filter to or null for no filtering</param>
            /// <param name="nodeId">Id of the parent node or null to browse the root node</param>
            /// <param name="ct">Cancellation token</param>
            public static List<(string NodeId, string NodeClass, bool Children)> GetBrowseEndpointRecursive(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string nodeClass = null,
                    string nodeId = null,
                    CancellationToken ct = default) {

                if (string.IsNullOrEmpty(endpointId)) {
                    context.OutputHelper.WriteLine($"{nameof(endpointId)} is null or empty");
                    throw new ArgumentNullException(nameof(endpointId));
                }

                var nodes = new ConcurrentBag<(string NodeId, string NodeClass, bool Children)>();

                GetBrowseEndpointRecursiveCollectResults(context, endpointId, nodes, nodeId, ct);

                return nodes.Where(n => string.Equals(nodeClass, n.NodeClass, StringComparison.OrdinalIgnoreCase)).ToList();
            }

            /// <summary>
            /// Collects all nodes recursively avoiding circular references between nodes
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="nodes">Collection of nodes found</param>
            /// <param name="nodeId">Id of the parent node or null to browse the root node</param>
            /// <param name="ct">Cancellation token</param>
            private static void GetBrowseEndpointRecursiveCollectResults(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    ConcurrentBag<(string NodeId, string NodeClass, bool Children)> nodes,
                    string nodeId = null,
                    CancellationToken ct = default) {

                var currentNodes = GetBrowseEndpoint(context, endpointId, nodeId);

                foreach (var node in currentNodes) {
                    ct.ThrowIfCancellationRequested();

                    if (nodes.Any(n => string.Equals(n.NodeId, node.NodeId))) {
                        continue;
                    }

                    nodes.Add(node);

                    if (node.Children) {
                        GetBrowseEndpointRecursiveCollectResults(
                            context,
                            endpointId,
                            nodes,
                            node.NodeId,
                            ct);
                    }
                }
            }

            /// <summary>
            /// Gets method metadata
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="methodId">Id of the method to get the metadata of</param>
            /// <param name="ct">Cancellation token</param>
            public static dynamic GetMethodMetadata(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string methodId = null,
                    CancellationToken ct = default) {

                var route = $"twin/v2/call/{endpointId}/metadata";
                var body = new {
                    methodId,
                    header = new {
                        diagnostics = new {
                            level = "Verbose"
                        }
                    }
                };
                var response = CallRestApi(context, Method.POST, route, body, ct: ct);
                return JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());
            }

            /// <summary>
            /// Reads node attributes
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="attributes">Attributes to be read</param>
            /// <param name="ct">Cancellation token</param>
            public static dynamic ReadNodeAttributes(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    List<object> attributes,
                    CancellationToken ct = default) {

                var route = $"twin/v2/read/{endpointId}/attributes";
                var body = new { attributes };
                var response = CallRestApi(context, Method.POST, route, body, ct: ct);
                return JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());
            }

            /// <summary>
            /// Writes node attributes
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="attributes">Attributes to be written</param>
            /// <param name="ct">Cancellation token</param>
            public static dynamic WriteNodeAttributes(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    List<object> attributes,
                    CancellationToken ct = default) {

                var route = $"twin/v2/write/{endpointId}/attributes";
                var body = new { attributes };
                var response = CallRestApi(context, Method.POST, route, body, ct: ct);
                return JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());
            }

            /// <summary>
            /// Calls a method
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="methodId">Id of the method to call</param>
            /// <param name="objectId">Object ID</param>
            /// <param name="arguments">Method arguments</param>
            /// <param name="ct">Cancellation token</param>
            public static dynamic CallMethod(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string methodId,
                    string objectId,
                    List<object> arguments,
                    CancellationToken ct = default) {

                var route = $"twin/v2/call/{endpointId}";
                var body = new {
                    methodId,
                    objectId,
                    arguments,
                    header = new {
                        diagnostics = new {
                            level = "Verbose"
                        }
                    }
                };

                var response = CallRestApi(context, Method.POST, route, body, ct: ct);
                return JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());
            }

            /// <summary>
            /// Browses nodes using a path from the specified node id
            /// </summary>
            /// <param name="context">Shared Context for E2E testing Industrial IoT Platform</param>
            /// <param name="endpointId">Id of the endpoint as returned by <see cref="Registry_GetEndpoints(IIoTPlatformTestContext)"/></param>
            /// <param name="nodeId">Node to browse from, if null defaults to root folder</param>
            /// <param name="browsePath">The paths to browse from node</param>
            /// <param name="ct">Cancellation token</param>
            public static dynamic GetBrowseNodePath(
                    IIoTPlatformTestContext context,
                    string endpointId,
                    string nodeId,
                    List<string> browsePath,
                    CancellationToken ct = default) {

                var route = $"twin/v2/browse/{endpointId}/path";
                var body = new {
                    nodeId,
                    browsePaths = new List<object> { browsePath }
                };

                var response = CallRestApi(context, Method.POST, route, body, ct: ct);
                return JsonConvert.DeserializeObject<ExpandoObject>(response.Content, new ExpandoObjectConverter());
            }
        }
    }
}