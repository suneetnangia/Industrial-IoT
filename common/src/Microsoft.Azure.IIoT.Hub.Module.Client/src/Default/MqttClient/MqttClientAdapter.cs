﻿// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.Module.Framework.Client.MqttClient {
    using Microsoft.Azure.IIoT.Exceptions;
    using Microsoft.Azure.Devices.Client;
    using Microsoft.Azure.Devices.Shared;
    using Serilog;
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Linq;
    using System.Security.Cryptography.X509Certificates;
    using System.Threading.Tasks;
    using System.Threading;
    using Prometheus;
    using Microsoft.Azure.IIoT.Hub.Module.Client.Default.MqttClient;
    using Newtonsoft.Json;
    using System.Text;
    using System.Collections.ObjectModel;
    using Microsoft.Azure.Devices.Client.Common;
    using MQTTnet.Client;
    using MQTTnet.Client.Disconnecting;
    using MQTTnet;
    using MQTTnet.Client.Options;
    using System.Security.Authentication;
    using MQTTnet.Client.Connecting;
    using System.Collections.Concurrent;
    using MQTTnet.Extensions.ManagedClient;
    using MQTTnet.Formatter;
    using System.Runtime.InteropServices;

    /// <summary>
    /// Injectable factory that creates clients
    /// </summary>
    public sealed partial class IoTSdkFactory {
        /// <summary>
        /// MQTT client adapter implementation
        /// </summary>
        public sealed class MqttClientAdapter : IClient {

            /// <summary>
            /// Whether the client is closed
            /// </summary>
            public bool IsClosed { get; private set; }

            /// <summary>
            /// Constructor
            /// </summary>
            /// <param name="client">MQTT server client.</param>
            /// <param name="product">Custom product information.</param>
            /// <param name="deviceId">Id of the device.</param>
            /// <param name="timeout">Timeout used for operations.</param>
            /// <param name="retry">Retry policy used for operations.</param>
            /// <param name="onConnectionLost">Handler for when the MQTT server connection is lost.</param>
            /// <param name="logger">Logger used for operations</param>
            /// <param name="messageExpiryInterval">Period of time (seconds) for the broker to store the message for any subscribers that are not yet connected</param>
            private MqttClientAdapter(IManagedMqttClient client, string product, string deviceId, TimeSpan timeout, IRetryPolicy retry, Action onConnectionLost, ILogger logger, uint? messageExpiryInterval) {
                _client = client ?? throw new ArgumentNullException(nameof(client));
                _product = product ?? throw new ArgumentNullException(nameof(product));
                _deviceId = deviceId ?? throw new ArgumentNullException(nameof(deviceId));
                _timeout = timeout;
                _retry = retry;
                _onConnectionLost = onConnectionLost ?? throw new ArgumentNullException(nameof(onConnectionLost));
                _logger = logger ?? throw new ArgumentNullException(nameof(logger));
                _messageExpiryInterval = messageExpiryInterval;
            }

            /// <summary>
            /// Create and connect an instance of the client adapter.
            /// </summary>
            /// <param name="client">MQTT server client.</param>
            /// <param name="product">Custom product information.</param>
            /// <param name="cs">Connection string for the MQTT server.</param>
            /// <param name="deviceId">Id of the device.</param>
            /// <param name="timeout">Timeout used for operations.</param>
            /// <param name="retry">Retry policy used for operations.</param>
            /// <param name="onConnectionLost">Handler for when the MQTT server connection is lost.</param>
            /// <param name="logger">Logger used for operations</param>
            /// <returns></returns>
            public static async Task<IClient> CreateAsync(IManagedMqttClient client, string product, MqttClientConnectionStringBuilder cs, string deviceId, TimeSpan timeout,
                IRetryPolicy retry, Action onConnectionLost, ILogger logger) {
                var options = new MqttClientOptionsBuilder()
                    .WithClientId(cs.DeviceId)
                    .WithTcpServer(tcpOptions => {
                        tcpOptions.Server = cs.HostName;
                        tcpOptions.Port = cs.Port;

                        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) {
                            tcpOptions.BufferSize = 64 * 1024;
                        }
                    });


                if (!string.IsNullOrWhiteSpace(cs.Username) && !string.IsNullOrWhiteSpace(cs.Password)) {
                    options = options.WithCredentials(cs.Username, cs.Password);
                }

                if (cs.UsingX509Cert) {
                    options = options.WithTls(new MqttClientOptionsBuilderTlsParameters {
                        UseTls = true,
                        SslProtocol = SslProtocols.Tls12,
                        Certificates = new List<X509Certificate> { cs.X509Cert },
                        IgnoreCertificateRevocationErrors = true
                    });
                }

                // Use MQTT 5.0 if message expiry interval is set.
                if (cs.MessageExpiryInterval != null) {
                    options = options.WithProtocolVersion(MqttProtocolVersion.V500);
                }

                var adapter = new MqttClientAdapter(client, product, deviceId, timeout, retry, onConnectionLost, logger, cs.MessageExpiryInterval);
                client.UseConnectedHandler(adapter.OnConnected);
                client.UseDisconnectedHandler(adapter.OnDisconnected);
                client.UseApplicationMessageReceivedHandler(adapter.OnApplicationMessageReceivedHandler);

                var managedOptions = new ManagedMqttClientOptionsBuilder()
                    .WithClientOptions(options.Build());

                if (cs.UsingStateFile) {
                    managedOptions = managedOptions.WithStorage(new ManagedMqttClientStorage(cs.StateFile, logger));
                }

                await adapter.InternalConnectAsync(managedOptions.Build());
                return adapter;
            }

            /// <summary>
            /// Create and connect an instance of the client adapter.
            /// </summary>
            /// <param name="product">Custom product information.</param>
            /// <param name="cs">Connection string for the MQTT server.</param>
            /// <param name="deviceId">Id of the device.</param>
            /// <param name="timeout">Timeout used for operations.</param>
            /// <param name="retry">Retry policy used for operations.</param>
            /// <param name="onConnectionLost">Handler for when the MQTT server connection is lost.</param>
            /// <param name="logger">Logger used for operations</param>
            /// <returns></returns>
            public static Task<IClient> CreateAsync(string product, MqttClientConnectionStringBuilder cs, string deviceId, TimeSpan timeout, 
                IRetryPolicy retry, Action onConnectionLost, ILogger logger) {
                var client = new MqttFactory().CreateManagedMqttClient();
                return CreateAsync(client, product, cs, deviceId, timeout, retry, onConnectionLost, logger);
            }

            /// <inheritdoc />
            public Task CloseAsync() {
                if (IsClosed) {
                    return Task.CompletedTask;
                }
                IsClosed = true;
                return _client.StopAsync();
            }

            /// <inheritdoc />
            public Task SendEventAsync(Message message) {
                if (IsClosed) {
                    return Task.CompletedTask;
                }

                var cancellationTokenSource = new CancellationTokenSource();
                cancellationTokenSource.CancelAfter(_timeout);

                try {
                    var mqttApplicationMessageBuilder = new MqttApplicationMessageBuilder()
                        .WithAtLeastOnceQoS()
                        .WithContentType(message.ContentType)
                        .WithTopic(PopulateMessagePropertiesFromMessage($"devices/{_deviceId}/messages/events/", message))
                        .WithPayload(message.BodyStream)
                        .WithRetainFlag(true);

                    if (_messageExpiryInterval != null) {
                        mqttApplicationMessageBuilder = mqttApplicationMessageBuilder.WithMessageExpiryInterval(_messageExpiryInterval.Value);

                    }

                    return _client.PublishAsync(mqttApplicationMessageBuilder.Build(), cancellationTokenSource.Token);
                }
                catch (Exception ex) {
                    _logger.Error($"Failed to send MQTT message: {ex.Message}");
                }
                return Task.CompletedTask;
            }

            /// <inheritdoc />
            public Task SendEventBatchAsync(IEnumerable<Message> messages) {
                if (IsClosed) {
                    return Task.CompletedTask;
                }
                return Task.WhenAll(messages.Select(x => SendEventAsync(x)));
            }

            /// <inheritdoc />
            public Task SetMethodHandlerAsync(string methodName,
                MethodCallback methodHandler, object userContext) {
                _logger.Warning($"Unsupported method called in MQTT client: {nameof(SetMethodHandlerAsync)}");
                return Task.CompletedTask;
            }

            /// <inheritdoc />
            public Task SetMethodDefaultHandlerAsync(
                MethodCallback methodHandler, object userContext) {
                _logger.Warning($"Unsupported method called in MQTT client: {nameof(SetMethodDefaultHandlerAsync)}");
                return Task.CompletedTask;
            }

            /// <inheritdoc />
            public Task SetDesiredPropertyUpdateCallbackAsync(
                DesiredPropertyUpdateCallback callback, object userContext) {
                _logger.Warning($"Unsupported method called in MQTT client: {nameof(SetDesiredPropertyUpdateCallbackAsync)}");
                return Task.CompletedTask;
            }

            /// <inheritdoc />
            public async Task<Twin> GetTwinAsync() {
                if (IsClosed) {
                    return null;
                }

                var cancellationTokenSource = new CancellationTokenSource();
                cancellationTokenSource.CancelAfter(_timeout);

                var requestId = Guid.NewGuid();
                var mqttMessage = new MqttApplicationMessageBuilder()
                    .WithAtLeastOnceQoS()
                    .WithContentType(kContentType)
                    .WithTopic($"$iothub/twin/GET/?$rid={requestId}")
                    .Build();

                // Signal that the response should be saved by setting the key.
                _responses[requestId] = null;

                Twin result = null;
                try {
                    // Publish message and wait for response to come back. The thread may be unblocked by other 
                    // simultaneous calls, so wait again if needed.
                    await _client.PublishAsync(mqttMessage, cancellationTokenSource.Token);
                    while (!cancellationTokenSource.Token.IsCancellationRequested) {
                        _responseHandle.WaitOne(_timeout);
                        _responseHandle.Reset();
                        if (_responses[requestId] != null) {
                            result = new Twin {
                                Properties = JsonConvert.DeserializeObject<TwinProperties>(Encoding.UTF8.GetString(_responses[requestId].Payload)),
                            };
                            break;
                        }
                    }

                    if (result == null) {
                        cancellationTokenSource.Token.ThrowIfCancellationRequested();
                    }
                }
                catch (TaskCanceledException) {
                    _logger.Error($"Failed to get twin due to timeout: {_timeout}");
                }
                catch (Exception ex) {
                    _logger.Error($"Failed to get twin: {ex.Message}");
                }

                _responses.Remove(requestId, out _);
                return result;
            }

            /// <inheritdoc />
            public Task UpdateReportedPropertiesAsync(TwinCollection reportedProperties) {
                if (IsClosed) {
                    return Task.CompletedTask;
                }

                var mqttMessage = new MqttApplicationMessageBuilder()
                    .WithAtLeastOnceQoS()
                    .WithContentType(kContentType)
                    .WithTopic("$iothub/twin/PATCH/properties/reported/?$rid=patch_temp")
                    .WithPayload(Encoding.UTF8.GetBytes(reportedProperties.ToJson()))
                    .Build();

                try {
                    return _client.PublishAsync(mqttMessage, CancellationToken.None);
                }
                catch (Exception) {
                    return Task.CompletedTask;
                }
            }

            /// <inheritdoc />
            public Task UploadToBlobAsync(string blobName, Stream source) {
                throw new NotImplementedException();
            }

            /// <inheritdoc />
            public Task<MethodResponse> InvokeMethodAsync(string deviceId, string moduleId,
                MethodRequest methodRequest, CancellationToken cancellationToken) {
                throw new NotSupportedException("MQTT client does not support methods");
            }

            /// <inheritdoc />
            public Task<MethodResponse> InvokeMethodAsync(string deviceId,
                MethodRequest methodRequest, CancellationToken cancellationToken) {
                throw new NotSupportedException("MQTT client does not support methods");
            }

            /// <inheritdoc />
            public void Dispose() {
                IsClosed = true;
                _client?.Dispose();
            }

            /// <summary>
            /// Connect the MQTT client.
            /// </summary>
            /// <param name="options">Options for the MQTT client connection</param>
            /// <returns>Whether the conneciton was successful.</returns>
            private async Task<bool> InternalConnectAsync(IManagedMqttClientOptions options) {
                try {
                    if (!_client.IsStarted) {
                        // Start the client which connects to the server in the background. Wait for the client to
                        // signal that it is connected before.
                        await _client.StartAsync(options);
                        _connectedHandle.WaitOne(_timeout);

                        // The managed client is too slow when subscribing to the topics and can miss immediate
                        // messages. Call the internal client and subscribe directly to solve the issue.
                        var topicFilters = new MqttTopicFilter[] {
                            new MqttTopicFilter { Topic = "$iothub/twin/res/#" },
                            new MqttTopicFilter { Topic = "$iothub/twin/PATCH/properties/desired/#" }
                        };
                        await _client.InternalClient.SubscribeAsync(topicFilters);
                        await _client.SubscribeAsync(topicFilters);
                    }
                    return true;
                }
                catch (TaskCanceledException) {
                    _logger.Error($"Failed to connect to MQTT broker due to timeout: {_timeout}");
                }
                catch (Exception ex) {
                    _logger.Error($"Failed to connect to MQTT broker due to: {ex.Message}");
                }
                return false;
            }

            /// <summary>
            /// Handler for when the MQTT client is connected.
            /// </summary>
            /// <param name="eventArgs">Event arguments.</param>
            /// <returns></returns>
            private void OnConnected(MqttClientConnectedEventArgs eventArgs) {
                _connectedHandle.Set();
                _logger.Information("{counter}: Device {deviceId} connected or reconnected", _reconnectCounter, _deviceId);
                kReconnectionStatus.WithLabels(_deviceId, DateTime.UtcNow.ToString()).Set(_reconnectCounter);
                _reconnectCounter++;
            }

            /// <summary>
            /// Handler for when the MQTT client is disconnected.
            /// </summary>
            /// <param name="eventArgs">Event arguments.</param>
            /// <returns></returns>
            private async void OnDisconnected(MqttClientDisconnectedEventArgs eventArgs) {
                _connectedHandle.Reset();
                _logger.Information("{counter}: Device {deviceId} disconnected due to {reason}", _reconnectCounter, _deviceId, eventArgs.Reason);
                kDisconnectionStatus.WithLabels(_deviceId, DateTime.UtcNow.ToString()).Set(_reconnectCounter);
                if (IsClosed) {
                    return;
                }

                // Try to reconnect.
                await Task.Delay(3000);
                if (!await InternalConnectAsync(_client.Options)) {
                    _onConnectionLost();
                }
            }

            /// <summary>
            /// Handler for when the MQTT client receives an application message.
            /// </summary>
            /// <param name="eventArgs">Event arguments.</param>
            /// <returns></returns>
            private void OnApplicationMessageReceivedHandler(MqttApplicationMessageReceivedEventArgs eventArgs) {
                if (eventArgs.ProcessingFailed) {
                    _logger.Warning("Failed to process message: {reasonCode}", eventArgs.ReasonCode);
                    return;
                }

                if (eventArgs.ApplicationMessage.Topic.StartsWith("$iothub/twin/res/200/?$rid=")) {
                    // Only store the response if a thread is waiting for it (indicated by key added).
                    var requestId = Guid.Parse(eventArgs.ApplicationMessage.Topic.Substring("$iothub/twin/res/200/?$rid=".Length, 36));
                    if (_responses.ContainsKey(requestId)) {
                        _responses[requestId] = eventArgs.ApplicationMessage;
                    }

                    // Unblock all threads waiting for responses.
                    _responseHandle.Set();
                }
            }

            /// <summary>
            /// Merge array of dictionaries.
            /// </summary>
            /// <param name="dictionaries">Dictionaries to merge.</param>
            /// <returns>Merged, read-only dictionary</returns>
            private static IReadOnlyDictionary<TKey, TValue> MergeDictionaries<TKey, TValue>(IDictionary<TKey, TValue>[] dictionaries) {
                // No item in the array should be null.
                if (dictionaries == null || dictionaries.Any(item => item == null)) {
                    throw new ArgumentNullException(nameof(dictionaries), "Provided dictionaries should not be null");
                }

                var result = dictionaries.SelectMany(dict => dict)
                    .ToLookup(pair => pair.Key, pair => pair.Value)
                    .ToDictionary(group => group.Key, group => group.First());
                return new ReadOnlyDictionary<TKey, TValue>(result);
            }

            /// <summary>
            /// Populate message properties from message.
            /// </summary>
            /// <param name="topicName">Name of topic.</param>
            /// <param name="message">Message from which to populate from.</param>
            /// <returns>Populated message.</returns>
            private static string PopulateMessagePropertiesFromMessage(string topicName, Message message) {
                var systemProperties = new Dictionary<string, string>();
                if (!string.IsNullOrWhiteSpace(message.ContentType))
                    systemProperties[kContentTypePropertyName] = message.ContentType;
                if (!string.IsNullOrWhiteSpace(message.ContentEncoding))
                    systemProperties[kContentEncodingPropertyName] = message.ContentEncoding;
                string properties = UrlEncodedDictionarySerializer.Serialize(MergeDictionaries(new IDictionary<string, string>[] { systemProperties, message.Properties }));

                string msg = properties.Length != 0
                    ? topicName.EndsWith(kSegmentSeparator, StringComparison.Ordinal) ? topicName + properties + kSegmentSeparator : topicName + kSegmentSeparator + properties
                    : topicName;
                if (Encoding.UTF8.GetByteCount(msg) > kMaxTopicNameLength) {
                    throw new MessageTooLargeException($"TopicName for MQTT packet cannot be larger than {kMaxTopicNameLength} bytes, " +
                        $"current length is {Encoding.UTF8.GetByteCount(msg)}." +
                        $" The probable cause is the list of message.Properties and/or message.systemProperties is too long. " +
                        $"Please use AMQP or HTTP.");
                }
                return msg;
            }

            private readonly IManagedMqttClient _client;

            private const int kMaxTopicNameLength = 0xffff;
            private const string kSegmentSeparator = "/";
            private const string kContentEncodingPropertyName = "iothub-content-encoding";
            private const string kContentTypePropertyName = "iothub-content-type";
            private const string kContentType = "application/json";

            private readonly string _product;
            private readonly string _deviceId;
            private readonly TimeSpan _timeout;
            private readonly IRetryPolicy _retry;
            private readonly Action _onConnectionLost;
            private readonly ILogger _logger;
            private readonly uint? _messageExpiryInterval;
            private ManualResetEvent _responseHandle = new ManualResetEvent(false);
            private ManualResetEvent _connectedHandle = new ManualResetEvent(false);
            private ConcurrentDictionary<Guid, MqttApplicationMessage> _responses = new ConcurrentDictionary<Guid, MqttApplicationMessage>();

            private int _reconnectCounter;
            private static readonly Gauge kReconnectionStatus = Metrics
                .CreateGauge("iiot_edge_device_reconnected", "reconnected count",
                    new GaugeConfiguration {
                        LabelNames = new[] { "device", "timestamp_utc" }
                    });
            private static readonly Gauge kDisconnectionStatus = Metrics
                .CreateGauge("iiot_edge_device_disconnected", "disconnected count",
                    new GaugeConfiguration {
                        LabelNames = new[] { "device", "timestamp_utc" }
                    });
        }
    }
}
