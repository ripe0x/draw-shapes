import { deployment } from "../lib/deployment";

export function NotDeployed({ children }: { children: React.ReactNode }) {
  if (deployment.deployed) return <>{children}</>;
  return <p className="note">The contracts are not deployed on this network yet.</p>;
}
