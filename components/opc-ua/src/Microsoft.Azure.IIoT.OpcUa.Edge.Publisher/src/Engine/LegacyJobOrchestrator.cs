// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.OpcUa.Edge.Publisher.Engine {
    using Microsoft.Azure.IIoT.Agent.Framework;
    using Microsoft.Azure.IIoT.Agent.Framework.Models;
    using Microsoft.Azure.IIoT.OpcUa.Edge.Publisher;
    using Microsoft.Azure.IIoT.OpcUa.Edge.Publisher.Models;
    using Microsoft.Azure.IIoT.OpcUa.Publisher.Config.Models;
    using Microsoft.Azure.IIoT.OpcUa.Publisher.Models;
    using Microsoft.Azure.IIoT.Exceptions;
    using Microsoft.Azure.IIoT.Module;
    using Serilog;
    using System;
    using System.Collections.Concurrent;
    using System.Collections.Generic;
    using System.IO;
    using System.Linq;
    using System.Net;
    using System.Security.Cryptography;
    using System.Text;
    using System.Threading;
    using System.Threading.Tasks;

    /// <summary>
    /// Job orchestrator the represents the legacy publishednodes.json with legacy command line arguments as job.
    /// </summary>
    public class LegacyJobOrchestrator : IJobOrchestrator, IPublisherConfigServices, IDisposable {
        /// <summary>
        /// Creates a new class of the LegacyJobOrchestrator.
        /// </summary>
        /// <param name="publishedNodesJobConverter">The converter to read the job from the specified file.</param>
        /// <param name="legacyCliModelProvider">The provider that provides the legacy command line arguments.</param>
        /// <param name="agentConfigProvider">The provider that provides the agent configuration.</param>
        /// <param name="jobSerializer">The serializer to (de)serialize job information.</param>
        /// <param name="logger">Logger to write log messages.</param>
        /// <param name="identity">Module's identity provider.</param>

        public LegacyJobOrchestrator(PublishedNodesJobConverter publishedNodesJobConverter,
            ILegacyCliModelProvider legacyCliModelProvider, IAgentConfigProvider agentConfigProvider,
            IJobSerializer jobSerializer, ILogger logger, IIdentity identity) {
            _publishedNodesJobConverter = publishedNodesJobConverter
                ?? throw new ArgumentNullException(nameof(publishedNodesJobConverter));
            _legacyCliModel = legacyCliModelProvider.LegacyCliModel
                    ?? throw new ArgumentNullException(nameof(legacyCliModelProvider));
            _agentConfig = agentConfigProvider
                    ?? throw new ArgumentNullException(nameof(agentConfigProvider));

            _jobSerializer = jobSerializer ?? throw new ArgumentNullException(nameof(jobSerializer));
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _identity = identity ?? throw new ArgumentNullException(nameof(identity));

            var directory = Path.GetDirectoryName(_legacyCliModel.PublishedNodesFile);

            if (string.IsNullOrWhiteSpace(directory)) {
                directory = Environment.CurrentDirectory;
            }

            _availableJobs = new ConcurrentQueue<JobProcessingInstructionModel>();
            _assignedJobs = new ConcurrentDictionary<string, JobProcessingInstructionModel>();

            _lock = new SemaphoreSlim(1, 1);

            _publishedNodesEntrys = new List<PublishedNodesEntryModel>();

            RefreshJobFromFile();

            var file = Path.GetFileName(_legacyCliModel.PublishedNodesFile);
            _fileSystemWatcher = new FileSystemWatcher(directory, file);
            _fileSystemWatcher.Changed += _fileSystemWatcher_Changed;
            _fileSystemWatcher.Created += _fileSystemWatcher_Created;
            _fileSystemWatcher.Renamed += _fileSystemWatcher_Renamed;
            _fileSystemWatcher.Deleted += _fileSystemWatcher_Deleted;
            _fileSystemWatcher.EnableRaisingEvents = true;
        }

        /// <summary>
        /// Gets the next available job - this will always return the job representation of the legacy publishednodes.json
        /// along with legacy command line arguments.
        /// </summary>
        /// <param name="workerId"></param>
        /// <param name="request"></param>
        /// <param name="ct"></param>
        /// <returns></returns>
        public async Task<JobProcessingInstructionModel> GetAvailableJobAsync(string workerId, JobRequestModel request, CancellationToken ct = default) {
            await _lock.WaitAsync(ct);
            try {
                ct.ThrowIfCancellationRequested();
                if (_assignedJobs.TryGetValue(workerId, out var job)) {
                    return job;
                }
                if (!_availableJobs.IsEmpty && _availableJobs.TryDequeue(out job)) {
                    _assignedJobs.AddOrUpdate(workerId, job);
                }

                return job;
            }
            catch (OperationCanceledException) {
                _logger.Information("Operation GetAvailableJobAsync was canceled");
                throw;
            }
            catch (Exception e) {
                _logger.Error(e, "Error while looking for available jobs, for {Worker}", workerId);
                throw;
            }
            finally {
                _lock.Release();
            }
        }

        /// <summary>
        /// Receives the heartbeat from the LegacyJobOrchestrator, JobProcess; used to control lifetime of job (cancel, restart, keep).
        /// </summary>
        /// <param name="heartbeat"></param>
        /// <param name="ct"></param>
        /// <returns></returns>
        public async Task<HeartbeatResultModel> SendHeartbeatAsync(HeartbeatModel heartbeat, CancellationToken ct = default) {
            await _lock.WaitAsync();
            try {
                ct.ThrowIfCancellationRequested();
                HeartbeatResultModel heartbeatResultModel;
                JobProcessingInstructionModel job = null;
                if (heartbeat?.Job != null) {
                    if (_assignedJobs.TryGetValue(heartbeat.Worker.WorkerId, out job)) {
                        if (job.Job.GetHashSafe() == heartbeat.Job.JobHash) {
                            // JobProcess should keep working
                            heartbeatResultModel = new HeartbeatResultModel {
                                HeartbeatInstruction = HeartbeatInstruction.Keep,
                                LastActiveHeartbeat = DateTime.UtcNow,
                                UpdatedJob = null,
                            };
                        }
                        else {
                            if (job.Job.Id == heartbeat.Job.JobId) {
                                // JobProcess have to finished current and process new job (if job != null) otherwise complete
                                //  TODO: since just the content of the datasets is changed, just trigger a job update
                                heartbeatResultModel = new HeartbeatResultModel {
                                    HeartbeatInstruction = HeartbeatInstruction.CancelProcessing,
                                    LastActiveHeartbeat = DateTime.UtcNow,
                                    UpdatedJob = job,
                                };
                            }
                            else {
                                // JobProcess have to finished current and process new job (if job != null) otherwise complete
                                heartbeatResultModel = new HeartbeatResultModel {
                                    HeartbeatInstruction = HeartbeatInstruction.CancelProcessing,
                                    LastActiveHeartbeat = DateTime.UtcNow,
                                    UpdatedJob = job,
                                };
                            }
                        }
                    }
                    else {
                        heartbeatResultModel = new HeartbeatResultModel {
                            HeartbeatInstruction = HeartbeatInstruction.CancelProcessing,
                            LastActiveHeartbeat = DateTime.UtcNow,
                            UpdatedJob = null,
                        };
                    }
                }
                else {
                    // usecase when called from Timer of Worker instead of JobProcess
                    heartbeatResultModel = new HeartbeatResultModel {
                        HeartbeatInstruction = HeartbeatInstruction.Keep,
                        LastActiveHeartbeat = DateTime.UtcNow,
                        UpdatedJob = null,
                    };
                }
                _logger.Debug("SendHeartbeatAsync updated worker {worker} with {heartbeatInstruction} instruction for job {jobId}.",
                    heartbeat.Worker.WorkerId,
                    heartbeatResultModel?.HeartbeatInstruction,
                    job?.Job?.Id);

                return heartbeatResultModel;
            }
            catch (OperationCanceledException) {
                _logger.Information("Operation SendHeartbeatAsync was canceled");
                throw;
            }
            catch (Exception e) {
                _logger.Error(e, "Exception on heartbeat for worker {worker} with job {jobId}",
                    heartbeat?.Worker?.WorkerId,
                    heartbeat?.Job?.JobId);
                throw;
            }
            finally {
                _lock.Release();
            }
        }

        /// <inheritdoc/>
        public void Dispose() {
            if (_fileSystemWatcher != null) {
                _fileSystemWatcher.EnableRaisingEvents = false;
                _fileSystemWatcher.Changed -= _fileSystemWatcher_Changed;
                _fileSystemWatcher.Created -= _fileSystemWatcher_Created;
                _fileSystemWatcher.Renamed -= _fileSystemWatcher_Renamed;
                _fileSystemWatcher.Deleted -= _fileSystemWatcher_Deleted;
                _fileSystemWatcher?.Dispose();
            }
            _lock?.Dispose();
        }

        private void _fileSystemWatcher_Changed(object sender, FileSystemEventArgs e) {
            _logger.Debug("File {publishedNodesFile} changed. Triggering file refresh ...", _legacyCliModel.PublishedNodesFile);
            RefreshJobFromFile();
        }

        private void _fileSystemWatcher_Created(object sender, FileSystemEventArgs e) {
            _logger.Debug("File {publishedNodesFile} created. Triggering file refresh ...", _legacyCliModel.PublishedNodesFile);
            RefreshJobFromFile();
        }

        private void _fileSystemWatcher_Renamed(object sender, FileSystemEventArgs e) {
            _logger.Debug("File {publishedNodesFile} renamed. Triggering file refresh ...", _legacyCliModel.PublishedNodesFile);
            RefreshJobFromFile();
        }

        private void _fileSystemWatcher_Deleted(object sender, FileSystemEventArgs e) {
            _logger.Debug("File {publishedNodesFile} deleted. Clearing configuration ...", _legacyCliModel.PublishedNodesFile);
            _lock.Wait();
            try {
                _availableJobs.Clear();
                _assignedJobs.Clear();
                _lastKnownFileHash = string.Empty;
            }
            finally {
                _lock.Release();
            }
        }

        private static string GetChecksum(string content) {
            if (string.IsNullOrEmpty(content)) {
                return null;
            }
            var sha = new SHA256Managed();
            var checksum = sha.ComputeHash(Encoding.UTF8.GetBytes(content));
            return BitConverter.ToString(checksum).Replace("-", string.Empty);
        }

        private void RefreshJobFromFile() {
            var retryCount = 3;
            var lastWriteTime = File.GetLastWriteTime(_legacyCliModel.PublishedNodesFile);
            while (true) {
                _lock.Wait();
                try {

                    using (var fileStream = new FileStream(_legacyCliModel.PublishedNodesFile, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                        var content = fileStream.ReadAsString(Encoding.UTF8);
                        var lastValidFileHash = _lastKnownFileHash;
                        var currentFileHash = GetChecksum(content);
                        if (currentFileHash != _lastKnownFileHash) {
                            _logger.Information("File {publishedNodesFile} has changed, last known hash {LastHash}, new hash {NewHash}, reloading...",
                                _legacyCliModel.PublishedNodesFile,
                                _lastKnownFileHash,
                                currentFileHash);

                            _lastKnownFileHash = currentFileHash;
                            if (!string.IsNullOrEmpty(content)) {
                                var availableJobs = new ConcurrentQueue<JobProcessingInstructionModel>();
                                var assignedJobs = new ConcurrentDictionary<string, JobProcessingInstructionModel>();
                                IEnumerable<PublishedNodesEntryModel> entries = null;

                                try {
                                    if (!File.Exists(_legacyCliModel.PublishedNodesSchemaFile)) {
                                        _logger.Information("Validation schema file {PublishedNodesSchemaFile} does not exist or is disabled, ignoring validation of {publishedNodesFile} file...",
                                        _legacyCliModel.PublishedNodesSchemaFile, _legacyCliModel.PublishedNodesFile);
                                        entries = _publishedNodesJobConverter.Read(content, null, _legacyCliModel);
                                    }
                                    else {
                                        using (var fileSchemaReader = new StreamReader(_legacyCliModel.PublishedNodesSchemaFile)) {
                                            entries = _publishedNodesJobConverter.Read(content, fileSchemaReader, _legacyCliModel);
                                        }
                                    }
                                }
                                catch (IOException) {
                                    throw; //pass it thru, to handle retries
                                }
                                catch (SerializerException ex) {
                                    _logger.Warning(ex, "Failed to deserialize {publishedNodesFile}, aborting reload...", _legacyCliModel.PublishedNodesFile);
                                    _lastKnownFileHash = lastValidFileHash;
                                    return;
                                }

                                var jobs = _publishedNodesJobConverter.ToWriterGroupJobs(entries, _legacyCliModel);
                                if (jobs.Any()) {
                                    foreach (var job in jobs) {
                                        var newJob = ToJobProcessingInstructionModel(job);
                                        var found = false;
                                        foreach (var assignedJob in _assignedJobs) {
                                            if (newJob?.Job?.Id != null && assignedJob.Value?.Job?.Id != null &&
                                                newJob.Job.Id == assignedJob.Value.Job.Id) {
                                                assignedJobs[assignedJob.Key] = newJob;
                                                found = true;
                                                break;
                                            }
                                        }
                                        if (!found) {
                                            availableJobs.Enqueue(newJob);
                                        }
                                    }
                                }
                                _availableJobs = availableJobs;
                                _assignedJobs = assignedJobs;

                                _publishedNodesEntrys.Clear();
                                _publishedNodesEntrys.AddRange(entries);
                            }
                            else {
                                _availableJobs.Clear();
                                _assignedJobs.Clear();
                            }

                            if (_agentConfig.Config.MaxWorkers < _availableJobs.Count + _assignedJobs.Count) {
                                _agentConfig.Config.MaxWorkers = _availableJobs.Count + _availableJobs.Count;
                            }
                            _agentConfig.TriggerConfigUpdate(this, new EventArgs());
                        }
                        else {
                            //avoid double events from FileSystemWatcher
                            if (lastWriteTime - _lastRead > TimeSpan.FromMilliseconds(10)) {
                                _logger.Information("File {publishedNodesFile} has changed and content-hash is equal to last one, nothing to do", _legacyCliModel.PublishedNodesFile);
                            }
                        }
                        _lastRead = lastWriteTime;
                        break;
                    }
                }
                catch (IOException ex) {
                    retryCount--;
                    if (retryCount > 0) {
                        _logger.Warning(ex, "Error while loading job from file. Retrying...");
                        Task.Delay(500).GetAwaiter().GetResult();
                    }
                    else {
                        _logger.Error(ex, "Error while loading job from file. Retry expired, giving up.");
                        break;
                    }
                }
                catch (SerializerException sx) {
                    _logger.Error(sx, "SerializerException while loading job from file.");
                    break;
                }
                catch (Exception e) {
                    _logger.Error(e, "Error while reloading {PublishedNodesFile}", _legacyCliModel.PublishedNodesFile);
                    _availableJobs.Clear();
                    _assignedJobs.Clear();
                    _lastKnownFileHash = string.Empty;
                }
                finally {
                    _lock.Release();
                }
            }
        }

        private JobProcessingInstructionModel ToJobProcessingInstructionModel (WriterGroupJobModel job){
            var jobId = job.GetJobId();

            job.WriterGroup.DataSetWriters.ForEach(d => {
                d.DataSet.ExtensionFields ??= new Dictionary<string, string>();
                d.DataSet.ExtensionFields["PublisherId"] = jobId;
                d.DataSet.ExtensionFields["DataSetWriterId"] = d.DataSetWriterId;
            });
            var endpoints = string.Join(", ", job.WriterGroup.DataSetWriters.Select(w => w.DataSet.DataSetSource.Connection.Endpoint.Url));
            _logger.Information($"Job {jobId} loaded. DataSetWriters endpoints: {endpoints}");
            var serializedJob = _jobSerializer.SerializeJobConfiguration(job, out var jobConfigurationType);

            return new JobProcessingInstructionModel {
                    Job = new JobInfoModel {
                        Demands = new List<DemandModel>(),
                        Id = jobId,
                        JobConfiguration = serializedJob,
                        JobConfigurationType = jobConfigurationType,
                        LifetimeData = new JobLifetimeDataModel(),
                        Name = jobId,
                        RedundancyConfig = new RedundancyConfigModel { DesiredActiveAgents = 1, DesiredPassiveAgents = 0 }
                    },
                    ProcessMode = ProcessMode.Active
                };
        }

        /// <inheritdoc/>
        public async Task<List<string>> PublishNodesAsync(PublishedNodesEntryModel request) {
            // TODO handle available jobs
            await _lock.WaitAsync().ConfigureAwait(false);
            try {
                _logger.Information("PublishNodes method triggered");
                var existingGroup = new List<PublishedNodesEntryModel>();
                foreach (var entry in _publishedNodesEntrys) {
                    if (entry.HasSameGroup(request)) {
                        if (request.DataSetWriterId == entry.DataSetWriterId &&
                            request.DataSetPublishingInterval == entry.DataSetPublishingInterval) {
                            entry.OpcNodes.AddRange(request.OpcNodes);
                        }
                        existingGroup.Add(entry);
                    }
                }

                if (!existingGroup.Any()) {
                    existingGroup.Add(request);
                    _publishedNodesEntrys.Add(request);
                }

                var jobs = _publishedNodesJobConverter.ToWriterGroupJobs(existingGroup, _legacyCliModel);
                var found = false;
                foreach (var job in jobs) {
                    var newJob = ToJobProcessingInstructionModel(job);
                    if (newJob == null) {
                        break;
                    }
                    foreach (var assignedJob in _assignedJobs) {
                        if (newJob.Job.Id == assignedJob.Value.Job.Id) {
                            _assignedJobs[assignedJob.Key] = newJob;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        _availableJobs.Enqueue(newJob);
                    }
                }
            }
            catch (MethodCallStatusException) {
                throw;
            }
            catch (Exception e) {
                throw new MethodCallStatusException((int)HttpStatusCode.BadRequest, e.Message);
            }
            finally {
                _lock.Release();
            }

            return new List<string> { "Succeded" };
        }

        /// <inheritdoc/>
        public async Task<List<string>> UnpublishNodesAsync(PublishedNodesEntryModel request) {
            // TODO handle available jobs
            await _lock.WaitAsync().ConfigureAwait(false);
            try {
                _logger.Information("UnpublishNodes method triggered");

                var existingGroup = new List<PublishedNodesEntryModel>();
                foreach (var entry in _publishedNodesEntrys.ToList()) {
                    if (entry.HasSameGroup(request)) {
                        if (request.DataSetWriterId == entry.DataSetWriterId &&
                            request.DataSetPublishingInterval == entry.DataSetPublishingInterval) {
                            foreach (var requestNode in request.OpcNodes) {
                                foreach (var entryNode in entry.OpcNodes) {
                                    if (requestNode.IsSame(entryNode)) {
                                        entry.OpcNodes.Remove(entryNode);
                                        break;
                                    }
                                }
                            }
                        }
                        existingGroup.Add(entry);
                    }
                }

                foreach (var entry in existingGroup) {
                    if (!entry.OpcNodes.Any()) {
                        _publishedNodesEntrys.Remove(entry);
                    }
                }

                if (existingGroup.Any()) {
                    var jobs = _publishedNodesJobConverter.ToWriterGroupJobs(existingGroup, _legacyCliModel);
                    var found = false;
                    foreach (var job in jobs) {
                        var newJob = ToJobProcessingInstructionModel(job);
                        if (newJob == null) {
                            var entryJobId = request.GetGroupId();
                            foreach (var assignedJob in _assignedJobs) {
                                if (entryJobId == assignedJob.Value.Job.Id) {
                                    _assignedJobs.Remove(assignedJob.Key, out _);
                                    break;
                                }
                            }
                        }
                        else {
                            foreach (var assignedJob in _assignedJobs) {
                                if (newJob.Job.Id == assignedJob.Value.Job.Id) {
                                    _assignedJobs[assignedJob.Key] = newJob;
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            throw new MethodCallStatusException((int)HttpStatusCode.NotFound, "Endpoint not found");
                        }
                    }
                }
                else {
                    throw new MethodCallStatusException((int)HttpStatusCode.NotFound, "Endpoint not found");
                }
            }
            catch (MethodCallStatusException){
                throw;
            }
            catch (Exception e) {
                throw new MethodCallStatusException((int)HttpStatusCode.BadRequest, e.Message);
            }
            finally {
                _lock.Release();
            }

            return new List<string> { "Succeded" };
        }

        /// <inheritdoc/>
        public async Task UnpublishAllNodesAsync() {
            await _lock.WaitAsync().ConfigureAwait(false);
            try {
                _logger.Information("UnpublishAllNodes method triggered");
                throw new MethodCallStatusException((int)HttpStatusCode.NotImplemented, "Not Implemented");
            }
            finally {
                _lock.Release();
            }
        }

        /// <inheritdoc/>
        public async Task GetConfiguredEndpointsAsync() {
            await _lock.WaitAsync().ConfigureAwait(false);
            try {
                _logger.Information("GetConfiguredEndpointsAsync method triggered");
                throw new MethodCallStatusException((int)HttpStatusCode.NotImplemented, "Not Implemented");
            }
            finally {
                _lock.Release();
            }
        }

        /// <inheritdoc/>
        public async Task GetConfiguredNodesOnEndpointAsync() {
            await _lock.WaitAsync().ConfigureAwait(false);
            try {
                _logger.Information("GetConfiguredNodesOnEndpointAsync method triggered");
                throw new MethodCallStatusException((int)HttpStatusCode.NotImplemented, "Not Implemented");
            }
            finally {
                _lock.Release();
            }
        }

        private readonly FileSystemWatcher _fileSystemWatcher;
        private readonly IJobSerializer _jobSerializer;
        private readonly LegacyCliModel _legacyCliModel;
        private readonly IAgentConfigProvider _agentConfig;
        private readonly IIdentity _identity;
        private readonly ILogger _logger;
        private readonly PublishedNodesJobConverter _publishedNodesJobConverter;
        private readonly SemaphoreSlim _lock;
        private readonly List<PublishedNodesEntryModel> _publishedNodesEntrys;
        private ConcurrentDictionary<string, JobProcessingInstructionModel> _assignedJobs;
        private ConcurrentQueue<JobProcessingInstructionModel> _availableJobs;
        private string _lastKnownFileHash;
        private DateTime _lastRead = DateTime.MinValue;
    }
}