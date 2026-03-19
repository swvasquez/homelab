# TODO

- **Cilium HTTP listener workaround** — [cilium/cilium#44123](https://github.com/cilium/cilium/issues/44123), fixed in
  [#44492](https://github.com/cilium/cilium/pull/44492) (expected in 1.20 stable). Cilium 1.19.x incorrectly filters
  the HTTP listener's Envoy config using HTTPS hostnames, breaking HTTP-to-HTTPS redirects. Workaround: explicit
  `hostname: '*.{{ dns_zone }}'` on the `http` listener in `hubble-gateway.yml.j2`. Remove it after upgrading to 1.20.
