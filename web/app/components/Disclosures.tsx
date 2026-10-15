/** Risks and controls shown before a deposit. */
export function Disclosures() {
  return (
    <ul className="disclosures">
      <li>Shares redeem at ordinary NAV per share. NAV can fall when captured items return less than their backing.</li>
      <li>A withdrawal pays from cash first and queues the remainder, which is paid in request order.</li>
      <li>The entry contribution funds the GRAIL buckets and leaves ordinary NAV.</li>
      <li>The admin can pause pulls and deposits, change bounded parameters and start an exit.</li>
      <li>An exit returns ordinary assets to holders at NAV, as cash on retirement or as successor shares on migration.</li>
    </ul>
  );
}
