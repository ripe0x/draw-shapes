import { SponsorPage } from "../components/SponsorPage";
import { getOfferRecord } from "../lib/offer";
import { getSponsorRecord } from "../lib/sponsorRecord";
import "./sponsor.css";

// The deal and offer records are read per request, so a record written after the build is used.
export const dynamic = "force-dynamic";

/** `/sponsor`: the standing offer when its record is present, else the sponsored prize deal, and how to lend a prize. */
export default function Page() {
  return <SponsorPage record={getSponsorRecord()} offer={getOfferRecord()} />;
}
