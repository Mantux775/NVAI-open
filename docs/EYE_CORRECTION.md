# Eyes in small faces

When a person is small in the picture (a whole figure, or framed from the knees up), video models often draw the eyes
as blurry, shapeless holes: the pupils are missing, and they change from frame to frame. The start image can be
perfectly clean; the damage starts in the first frame of the video.

## Why it happens

Video models do not compute every pixel. They first compress the picture into a much smaller grid and generate that
grid. MiniMax H3 combines 32 × 32 pixels into one unit (its model card: 16-fold compression, then 2 × 2 cells per
token); LTX-2.5 compresses about as strongly. At 1344 × 768 a face from the knees up is about 105 px tall, which is
only about three units; one eye is smaller than a single unit. The model has no room for a pupil and invents one, a
little differently in every frame. Another seed does not change that.

Measured with a man walking toward the camera, face about 105 px at 1344 × 768:

| Version | Eyes |
|---|---|
| Start image (1920 × 1088, face 147 px) | clean |
| The same start image scaled down to 1344 × 768 | still recognizable |
| First frame of the video at 1344 × 768 | gray, pupils missing |
| First frames of the video at 1920 × 1088 (face about 150 px) | pupils present |
| 1344 × 768 with the face recomputed (see below) | clean in every frame |

## What helps

1. **Closer framing.** From the waist up or closer, the face gets 250 px and more; then the model has enough units
   for the eyes. This is the most reliable fix when the shot allows it.
2. **Draft, then final.** Check a take quickly as a draft and render the best one again at the final size with the
   same seed. In NVAI-open: under a finished video "⇧ Render final" (Generate), or "⇧ Final" at the scene (Studio).
   MiniMax H3: draft 1344 × 768, final 1920 × 1088 (on a 16 GB card measured for 3 s in about 18 minutes, 15.3 GB of
   video memory; cards with more memory carry longer clips, not measured). LTX-2.5: draft 1280 × 704 in the standard
   way (5 s in about 93 s), final 1920 × 1088 with best quality (DFR, 5 s in about 13 minutes). The final take is
   similar to the draft, not identical: the noise changes with the size.
3. **Recompute the face.** Under a finished image or video "☺ Recompute face" (Generate), or under the takes of a
   scene (Studio, field "original photo of the person"). One frame of the clip is redrawn with FLUX 3 and the original
   photo; the facial features of the clip are blurred first, so the face comes from the photo and does not drift with
   the clip. Head pose, headgear, light and background stay. In a video a tracker lays this face onto the moving head
   in every frame and matches the light frame by frame. The eyes are the same, clean ones in every frame. The result
   is a new take; the old one stays. NVAI-open usually finds the photo by itself (from "Person from a photo", back
   through start image and still); otherwise drag one into the field. About 1 minute for an image, about 75 seconds
   for 3 seconds of video.

   Limit: mouth and eyelids come from the one recomputed frame and no longer move. For clips without speech (walking,
   looking, turning); with speech rather frame closer or use "⇧ Final".

## What does not help

- **Another seed:** the eyes are lost in the compression, every seed loses them.
- **Upscaling the finished video** (RelayVSR, SeedVR2 and similar): they sharpen what is there, a blurry hole
  becomes a sharp hole. With small faces RelayVSR can also give a painted look.
- **Face restorers that work frame by frame** (GFPGAN, CodeFormer and others): they redraw the eyes, but differently
  in every frame, so the face flickers. Several of them may not be used commercially.

## Guide: one person in five roles

A person walks toward the camera and changes role about every second, say firefighter, emergency doctor, police
officer, plumber, construction worker. The crossfade looks like a morph because face, posture, street and light stay and
only the clothes and the tool change. Everything works in the NVAI-open interface.

1. **Photo.** A frontal, sharp portrait: a photo of your own (with the person's consent) or one made under Generate →
   Image.
2. **Start image of the first role.** Generate → Image, "Person from a photo": crop the photo to head and shoulders,
   FLUX 3, size 1920 × 1088. In the prompt: role, clothes and tool, "walks toward the camera down the middle of a dark
   street at night", the framing ("framed from the knees up, his head near the top edge") and light from the front
   ("a soft, bright light from the front keeps his face and eyes clearly lit"), backlight low behind the legs, never at
   head height. Render four variants and check the eyes at full size.
3. **Studio project.** 1920 × 1080, five video scenes side by side, one per role. Model MiniMax H3 (mind its license) or
   LTX-2.5, path "With start image"; scene 1 gets the start image.
4. **Prompt per scene,** the same except for the role, for example:

   > Realistic live-action cinematic look. The firefighter from the first frame, in full turnout gear and helmet,
   > strides toward the camera down the middle of a dark, hazy street at night, a red fire extinguisher hanging from
   > his right hand. He walks at a natural, confident pace, one step after another, and comes closer with every step.
   > His face stays exactly as in the first frame. He looks straight into the camera with a calm, serious but friendly
   > expression, his mouth closed. A soft, bright light from the front keeps his face and eyes clearly lit; behind him
   > a warm light glows low on the wet asphalt, thin haze drifts through the street and the lights shimmer and ripple
   > in the puddles. The camera at waist height slowly glides backward down the street ahead of him, a little slower
   > than he walks, so the wet street, the lights and the buildings move past on both sides while he still comes
   > closer. His boots splash softly on the wet asphalt.

   Name what should move in the background, or the street stands still. 3 seconds are enough (MiniMax: 73 frames);
   each role uses a little more than one second.
5. **Generate scene 1** at the draft size (MiniMax 1344 × 768) and check it: walk, face, motion. If the take fits,
   "☺ Recompute face" under the takes, with the photo from step 1 (the field usually fills itself). The new take has
   clean eyes and the face of the photo. Put the take into the edit. (Instead of recomputing, "⇧ Final" at
   1920 × 1088 with the same seed also works, but takes about 18 instead of 1 to 2 minutes.)
6. **Cut point.** Trim the clip in the edit to its length, about 1.0 s. If the person comes toward the camera fast,
   rather shorter, or they are too close by the last role. Right-click the last frame of the clip → "Still image here
   into the media".
7. **Dress the next role.** Under Generate open the still → "✎ Rework" (FLUX 3, size 1920 × 1088). In the prompt say
   in two sentences what goes and what is new:

   > Edit the image: change only his clothes and what he carries. He no longer wears the firefighter turnout gear and
   > the black firefighter helmet. He now wears a red emergency doctor jacket with yellow and silver reflective stripes,
   > dark trousers and a plain white rescue helmet. He now has a plain red emergency medical case hanging from his right
   > hand; it is the only thing in his hands, and his shoulders are free. Keep everything else exactly unchanged: his
   > face, his body position and stride, his position and size in the frame (framed from the knees up, his head near
   > the top edge, exactly as large as in the image), the camera framing, the light, the street and the background.

   Do not write "Replace A with B": if the description of A itself contains a "with", the old clothes can stay. Do not
   name the old tool at all, not even as gone: a plunger carried over the shoulder stayed in every picture otherwise;
   with "it is the only thing in his hands, and his shoulders are free" it was gone. Do not name anything outside the
   frame (shoes), or the picture zooms out. Of four variants take the one whose size and position match the still and
   whose eyes are clean.
8. **Start image of the next scene.** Drag the chosen image from the media onto "Start image" of scene 2, generate
   scene 2, check it and recompute the face as in step 5. That way the face stays the one of the photo through all
   roles and does not drift further from clip to clip.
9. **Crossfade.** Put clip 2 right after clip 1, transition at the start: dissolve 0.4 s. The outgoing clip keeps
   playing past its end. MiniMax stands almost still for about six frames at the start of a clip while the previous one
   walks on: trim a few frames off the start of clip 2 until the heads lie on top of each other during the crossfade.
   Check frame by frame; if they sit side by side, the eyes double.
10. **Repeat** for the other roles. From the fourth on the person is so close that a tool carried low slides out of the
    bottom of the frame: then have it carried high ("carried over his right shoulder").
11. **Music.** Generate it with Stable Audio 3 a few seconds longer than the video; in the edit move only its start
    until the full entry falls on the first role change and the ending on the end of the video.
12. **Export**, for example YouTube 1080p.

Times on a 16 GB card: start images with FLUX 3 about 45 s each, a MiniMax draft of 3 s about 7 minutes, recomputing
the face about 75 s (a final at 1080p would take about 18 minutes).

## Notes

- Others solve the same problem with a face pass of the video model itself: the face is tracked, cut out large,
  computed again at low strength and blended back (for MiniMax H3 the ComfyUI extension "H3-FaceRefine"). The
  tracking box has to sit still on a moving person, or the face "boils".
- Results of MiniMax H3 are subject to its license: without a separate permission from MiniMax they must not be used
  in the EU, the UK, South Korea or the USA, private use included.
- Measured on an RTX 5060 Ti with 16 GB.
