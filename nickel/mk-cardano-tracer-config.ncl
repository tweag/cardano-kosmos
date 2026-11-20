fun input network_magic =>
{
  ekgRequestFreq = null,
  ekgRequestFull = null,
  hasEKG = null,
  hasForwarding = null,
  hasPrometheus = { epForceSSL = false, epHost = input.prometheus.address, epPort = input.prometheus.port },
  hasTimeseries = null,
  loRequestNum = null,
  logging = [
    {
      logFormat = "ForMachine",
      logMode = "FileMode",
      logRoot = "%{input.directory}/logs/"
    }
  ],
  metricsHelp = null,
  metricsNoSuffix = null,
  network = { contents = "%{input.directory}/socket/sock", tag = "AcceptAt" },
  networkMagic = network_magic,
  prometheusLabels = null,
  resourceFreq = null,
  rotation = {
    rpFrequencySecs = 60,
    rpKeepFilesNum = 10,
    rpLogLimitBytes = 50000000,
    rpMaxAgeMinutes = 3 * 24 * 60,
  },
  tlsCertificate = null,
  verbosity = null
}
