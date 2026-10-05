@CONNECT@

if [ "$mgmt_missing" = true ]; then
  echo "Error: kind management cluster $kind_name doesn't exist — nothing to scale" >&2
  exit 1
fi

@SPEC@

# The class can't change on a live cluster; keep the current one.
current_class=$(mk get "$cluster_res" "$name" -o jsonpath='{.spec.topology.classRef.name}')
patch_file=$(mktemp)
printf 'spec:\n' > "$patch_file"
if [ -n "$current_class" ] && [ "$current_class" != "$class" ]; then
  echo "⚠️  cluster_class changed ($current_class → $class) — not applied; recreate the cluster to change it"
  sed "s/^      name: $class\$/      name: $current_class/" "$topology_file" >> "$patch_file"
else
  cat "$topology_file" >> "$patch_file"
fi

echo "Patching $ns/$name: version $version, ${cp_count:-managed} control plane, $workers workers"
mk patch "$cluster_res" "$name" --type merge --patch-file "$patch_file"
