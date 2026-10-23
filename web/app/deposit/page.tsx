import { redirect } from "next/navigation";

/** Public deposits are gone: the engine treasury is the only shareholder. The old route points at
 *  the founder funding page. */
export default function DepositPage() {
  redirect("/fund");
}
