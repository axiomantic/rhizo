# rhizo/tests/config.nims
let siblingTripwire = thisDir() & "/../../tripwire/src"
if dirExists(siblingTripwire):
  switch("path", siblingTripwire)
switch("path", "../src")
switch("path", "plugins")
switch("import", "tripwire/auto")
switch("import", "redis_tripwire")
switch("define", "tripwireActive")
switch("define", "inProcessTest")
switch("define", "TripwireCapThreshold:500")
switch("warning", "UnusedImport:off")
