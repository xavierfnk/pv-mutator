# pv-mutator
A basic script to automate migration of StorageClass and reduction of Volumes storage size.
This is currently a Proof of Concept, so it is written in Bash in a way I found the simplest.
It is very far from perfect but I hope it will help!

I found that creating this script might be useful as it helps saving some time, because it is not possible to quickly reduce size of a volume or change its StorageClass in Kubernetes.

## Dependencies

To run this script, you will need:
- kubectl
- yq
- [pv-migrate by utkuozdemir](https://github.com/utkuozdemir/pv-migrate)

## How it works

The script is basically doing these steps:

1. Detects if a ReplicaSet or StatefulSet associated with your PVC is running, and asks to shut it down
2. Create a temporary PVC with the correct target class and size
3. Run `pv-migrate` to transfer data between the original PVC (old PV) and temporary PVC (new PV)
4. Delete the temporary PVC (reclaimPolicy is set on `Retain` at this point)
5. Change original PVC and new PV objects so that they can be associated with each other
6. If a StatefulSet was detected at Step 1, delete it and recreate it identical but with modified volumeClaimTemplate, to match the new PVC

## Usage

Provide information on the target PVC when running the script.
As of now, all variables are required but it will be changed.

You need to provide few things to the script:
- Name of the PVC you want to migrate
- Namespace it is in
- Target StorageClass (needs to be created before)
- Target size of the volume

The script is using your current Kubecontext.

Example:
```
$ NAMESPACE="default" PVC_NAME="www-web-0" CLASS="gp3" SIZE="5Gi" ./pv-mutator.sh
```

Note that you will have to delete the old PV yourself, once you see that migration went well and all your data is safe.

If you have a StatefulSet with multiple replicas (let's say 3), you can run the script once for each PVC with the StatefulSet still running for the first one, and scale it back when the 3 PVCs has been migrated. By doing so, StatefulSet's claim template will be modified thanks to the script (only once, since it won't be running for the following 2 PVCs).
