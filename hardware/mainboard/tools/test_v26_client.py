import threading,time,unittest
from v26_client import V26Control

class RequestTests(unittest.TestCase):
    def test_old_same_id_ack_does_not_complete_new_request(self):
        c=V26Control.__new__(V26Control)
        c.req=0;c.running=True;c.cv=threading.Condition()
        c.latest={"reply_req":1,"reply_status":0,"received_ns":0}
        class Transport:
            def sendto(self,packet,target):
                def reply():
                    time.sleep(.03)
                    with c.cv:
                        c.latest={"reply_req":1,"reply_status":0,"received_ns":time.monotonic_ns()}
                        c.cv.notify_all()
                threading.Thread(target=reply).start()
        c.tx=Transport();c.target=("127.0.0.1",0)
        started=time.monotonic()
        c.request(1,1,0,4)
        self.assertGreaterEqual(time.monotonic()-started,.025)
    def test_entire_configuration_retries_then_reports_verified(self):
        c=V26Control.__new__(V26Control)
        count=[]
        def attempt(changes):
            count.append(dict(changes))
            if len(count)<2:raise RuntimeError("temporary conflict")
            return {"cfg_id":7}
        c.apply_once=attempt
        self.assertEqual(c.apply({0:4,6:344})["cfg_id"],7)
        self.assertEqual(count,[{0:4,6:344}]*2)
    def test_invalid_ranges_never_reach_transport(self):
        c=V26Control.__new__(V26Control)
        c.apply_once=lambda changes:self.fail("Transport should not be called")
        with self.assertRaises(ValueError):c.apply({3:1801})
if __name__=="__main__":unittest.main()
