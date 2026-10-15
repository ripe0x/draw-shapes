import { SponsorPage } from "../components/SponsorPage";
import { getSponsorRecord } from "../lib/sponsorRecord";
import "./sponsor.css";

// The deal record is read per request, so a record written after the build is used.
export const dynamic = "force-dynamic";

/** `/sponsor`: the sponsored prize deal read from the deal record, and how to lend a prize. */
export default function Page() {
  return <SponsorPage record={getSponsorRecord()} />;
}
