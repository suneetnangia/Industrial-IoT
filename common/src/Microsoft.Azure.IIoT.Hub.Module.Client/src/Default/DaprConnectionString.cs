﻿namespace Microsoft.Azure.IIoT.Module.Framework.Client {
    using System;
    using System.Collections.Generic;
    using System.Linq;

    /// <summary>
    /// Connection string for the Dapr runtime.
    /// </summary>
    public class DaprConnectionString {
        private const string kHttpEndpointPropertyName = nameof(HttpEndpoint);
        private const string kGrpcEndpointPropertyName = nameof(GrpcEndpoint);
        private const string kApiTokenPropertyName = nameof(ApiToken);
        private const string kPubSubPropertyName = nameof(PubSub);
        private const string kTopicPropertyName = nameof(Topic);

        private const string kDefaultHttpEndpoint = "http://localhost:{DAPR_HTTP_PORT}";
        private const string kDefaultGrpcEndpoint = "http://localhost:{DAPR_GRPC_PORT}";
        private const string kDefaultApiToken = null;
        private const string kDefaultPubSub = "pubsub";
        private const string kDefaultTopic = "opcua";

        /// <summary>
        /// HTTP endpoint for the Dapr runtime.
        /// </summary>
        public string HttpEndpoint { get; }

        /// <summary>
        /// gRPC endpoint for the Dapr runtime.
        /// </summary>
        public string GrpcEndpoint { get; }

        /// <summary>
        /// API token for the Dapr runtime.
        /// </summary>
        public string ApiToken { get; }

        /// <summary>
        /// Name of the pubsub component.
        /// </summary>
        public string PubSub { get; }

        /// <summary>
        /// Name of the topic.
        /// </summary>
        public string Topic { get; }

        /// <summary>
        /// Constructor for the Dapr connection string.
        /// </summary>
        /// <param name="httpEndpoint">HTTP endpoint for the Dapr runtime.</param>
        /// <param name="grpcEndpoint">gRPC endpoint for the Dapr runtime.</param>
        /// <param name="apiToken">API token for the Dapr runtime.</param>
        /// <param name="pubSub">Name of the pubsub component.</param>
        /// <param name="topic">Name of the topic.</param>
        public DaprConnectionString(string httpEndpoint, string grpcEndpoint, string apiToken, string pubSub, string topic) {
            if (string.IsNullOrWhiteSpace(httpEndpoint)) {
                throw new ArgumentException("Value cannot be null or empty.", nameof(httpEndpoint));
            }
            if (string.IsNullOrWhiteSpace(grpcEndpoint)) {
                throw new ArgumentException("Value cannot be null or empty.", nameof(grpcEndpoint));
            }
            if (string.IsNullOrWhiteSpace(pubSub)) {
                throw new ArgumentException("Value cannot be null or empty.", nameof(pubSub));
            }
            if (string.IsNullOrWhiteSpace(topic)) {
                throw new ArgumentException("Value cannot be null or empty.", nameof(topic));
            }

            HttpEndpoint = httpEndpoint;
            GrpcEndpoint = grpcEndpoint;
            ApiToken = apiToken;
            PubSub = pubSub;
            Topic = topic;
        }

        /// <summary>
        /// Parse raw connection string for the Dapr runtime.
        /// </summary>
        /// <param name="daprConnectionString">Raw connectiong string for the Dapr runtime.</param>
        /// <returns>A Dapr runtime connection string.</returns>
        public static DaprConnectionString Create(string daprConnectionString) {
            if (daprConnectionString == null) {
                throw new ArgumentNullException(nameof(daprConnectionString));
            }

            // Parse connection string.
            var properties = daprConnectionString
                .Split(';')
                .Select(x => {
                    if (x.Length < 3 || x.Count(x => x == '=') != 1) {
                        throw new ArgumentException("Malformated connection string.");
                    }

                    var components = x.Split('=');
                    var key = components[0];
                    var value = components[1];
                    return new KeyValuePair<string, string>(key, value);
                })
                .ToDictionary(x => x.Key, x => x.Value);

            // Map properties.
            if (!properties.TryGetValue(kHttpEndpointPropertyName, out string httpEndpoint)) {
                httpEndpoint = kDefaultHttpEndpoint;
            }
            if (!properties.TryGetValue(kGrpcEndpointPropertyName, out string grpcEndpoint)) {
                grpcEndpoint = kDefaultGrpcEndpoint;
            }
            if (!properties.TryGetValue(kApiTokenPropertyName, out string apiToken)) {
                apiToken = kDefaultApiToken;
            }
            if (!properties.TryGetValue(kPubSubPropertyName, out string pubSub)) {
                pubSub = kDefaultPubSub;
            }
            if (!properties.TryGetValue(kTopicPropertyName, out string topic)) {
                topic = kDefaultTopic;
            }
            return new DaprConnectionString(httpEndpoint, grpcEndpoint, apiToken, pubSub, topic);
        }
    }
}
