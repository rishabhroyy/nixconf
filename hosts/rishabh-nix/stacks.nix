# Container stacks, derived from containers.nix: a stack is its Tailscale
# sidecar plus every container in its network. Used by configuration.nix
# (stop-/start- helpers) and homelab.nix (the dashboard's service list).
containers: {
  names = map (name: builtins.substring 10 (-1) name)
    (builtins.filter (name: builtins.substring 0 10 name == "tailscale-") (builtins.attrNames containers));
  units = stack: map (name: "docker-${name}.service") (builtins.filter (name:
    name == "tailscale-${stack}"
    || builtins.elem "--network=container:tailscale-${stack}" (containers.${name}.extraOptions or [])
  ) (builtins.attrNames containers));
}
