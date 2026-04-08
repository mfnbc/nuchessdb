use ./modules/sync.nu *

let result = (sync-state-transition-demo)

let scanned_missing = ($result.scanned.missing_archives)
let scanned_completed = ($result.scanned.completed_archives)
let retried_missing = ($result.retried.missing_archives)
let retried_completed = ($result.retried.completed_archives)

if $scanned_missing != ['2024/02' '2024/04'] {
  error make { msg: $'unexpected missing after scan: ($scanned_missing)' }
}

if $scanned_completed != ['2024/01' '2024/03' '2024/05'] {
  error make { msg: $'unexpected completed after scan: ($scanned_completed)' }
}

if $retried_missing != ['2024/04'] {
  error make { msg: $'unexpected missing after retry: ($retried_missing)' }
}

if not ($retried_completed | any { |m| $m == '2024/02' }) {
  error make { msg: 'retry did not add recovered month to completed_archives' }
}

print 'sync-state-test-ok'
