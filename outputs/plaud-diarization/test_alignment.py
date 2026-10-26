import unittest
from alignment import align, cues

def seg(a,b,s): return dict(startTimeSeconds=a,endTimeSeconds=b,speakerId=s)
def word(a,b,t='original'): return dict(startTime=a,endTime=b,word=t)
class AlignmentTests(unittest.TestCase):
    def test_boundary(self):
        x=align([word(.8,1.2)], [seg(0,1,'S1'),seg(1,2,'S2')],2)[0]
        self.assertEqual(x['alignment']['status'],'turn_boundary'); self.assertIsNone(x['speaker'])
    def test_gap(self):
        x=align([word(1,2)], [seg(0,1,'S1'),seg(2,3,'S2')],3)[0]
        self.assertEqual(x['speakerLabel'],'UNKNOWN')
    def test_overlap(self):
        x=align([word(1,2)], [seg(0,3,'S1'),seg(1.5,3,'S2')],3)[0]
        self.assertEqual(x['alignment']['status'],'overlap'); self.assertAlmostEqual(x['alignment']['simultaneousOverlapSeconds'],.5)
    def test_partial(self):
        x=align([word(0,1)], [seg(.5,1,'S1')],1)[0]
        self.assertEqual(x['alignment']['status'],'partial'); self.assertIsNone(x['speaker'])
    def test_duplicate_intervals_union(self):
        x=align([word(0,1)], [seg(0,1,'S1'),seg(0,1,'S1')],1)[0]
        self.assertEqual(x['speaker'],'S1'); self.assertEqual(x['alignment']['candidates'][0]['overlapSeconds'],1)
    def test_zero_and_eof(self):
        x=align([word(1,1),word(2,3)], [seg(0,2,'S1')],2)
        self.assertEqual(x[0]['speakerLabel'],'UNKNOWN'); self.assertEqual(x[1]['alignedEndTime'],2)
    def test_no_four_cap_and_words_preserved(self):
        ws=[word(i,i+.5,str(i)) for i in range(7)]
        x=align(ws,[seg(i,i+1,'S'+str(i)) for i in range(7)],7)
        self.assertEqual(len(set(w['speaker'] for w in x)),7)
        self.assertEqual([w['word'] for w in x],[w['word'] for w in ws])
        self.assertEqual(sum(len(c['wordIndices']) for c in cues(x)),7)
    def test_invalid(self):
        with self.assertRaises(ValueError): align([word(2,1)],[],3)
if __name__=='__main__': unittest.main()
