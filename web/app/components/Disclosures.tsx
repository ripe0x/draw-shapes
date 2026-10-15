/** Risks and controls shown before a deposit. */
export function Disclosures() {
  return (
    <ul className="disclosures">
      <li>Shares redeem at ordinary NAV per share. NAV can fall when captured items return less than their backing.</li>
      <li>A withdrawal pays from cash first and queues the remainder, which is paid in request order.</li>
      <li>The entry contribution funds the GRAIL and leaves ordinary NAV.</li>
      <li>Capital above the cash reserve mints Shapes for the board. Shapes charges a mint fee per Shape, about 5 percent of the capital it mints, paid from NAV to the Shapes operator.</li>
      <li>The admin can pause pulls and deposits, change bounded parameters and start an exit.</li>
      <li>An exit returns ordinary assets to holders at NAV, as cash on retirement or as successor shares on migration.</li>
    </ul>
  );
}
